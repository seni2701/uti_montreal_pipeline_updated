"""
01b_load_energie.py
-------------------
Chargement des couches SOURCES du volet HYDROÉLECTRIQUE (UTI-T2H électrique)
dans le schéma `raw` de PostGIS, en EPSG:2950.

Convention CARTHAB : 01_load_data.py n'est pas modifié. Ce script suffixé
prend en charge les seules clés réellement présentes dans config.yaml.

Usage :
    python scripts/01b_load_energie.py
    python scripts/01b_load_energie.py --no-clip     # pas de découpe territoriale
    python scripts/01b_load_energie.py --inspect     # diagnostic seul, aucune écriture

Ce script REFUSE de charger une couche dont le CRS est absent, et SIGNALE
explicitement :
  - l'absence d'attribut de tension (bloquant pour les buffers TRANSPORT) ;
  - toute source sous licence non commerciale (réserve juridique).
"""

import argparse
import sys
from pathlib import Path

import geopandas as gpd
import yaml
from sqlalchemy import text

from utils.db import get_engine

ROOT = Path(__file__).resolve().parents[1]
CONFIG = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))
TARGET_EPSG = CONFIG["crs"]["target_epsg"]

# ----------------------------------------------------------------------------
# Correspondance clé config.yaml -> table raw
# Seules les clés RÉELLEMENT présentes dans config.yaml figurent ici.
#
# NOTE : elec_poteaux_distrib a été RETIRÉ. poles_mtl.shp est la géobase des
# côtés de rue (Livrable A), sans aucun attribut électrique. Le corpus ne
# contient donc AUCUNE donnée de réseau de distribution.
# ----------------------------------------------------------------------------
TABLES_ENERGIE = {
    "elec_axe_transport": "elec_axe_transport",   # CARTO_SER_ELE_TEL_AERIEN (lignes)
    "elec_pylones":       "elec_pylones",         # CARTO_SER_ELECTRICITE (bases béton)
    "elec_emprises_hq":   "elec_emprises_hq",      # travaux_degagement_transport (CC BY-NC)
}

# Métadonnées de gouvernance
METADONNEES = {
    "elec_axe_transport": {
        "source_donnee": "VMTL_2020",
        "licence": "CC-BY",
        "reseau": "TRANSPORT",
        "geom_attendue": ("LineString", "MultiLineString"),
    },
    "elec_pylones": {
        "source_donnee": "VMTL_2020",
        "licence": "CC-BY",
        "reseau": "TRANSPORT",
        "geom_attendue": ("Point", "MultiPoint", "Polygon", "MultiPolygon"),
    },
    "elec_emprises_hq": {
        "source_donnee": "HQ_VEGETATION",
        "licence": "CC BY-NC 4.0",   # <-- RÉSERVE JURIDIQUE
        "reseau": "TRANSPORT",
        "geom_attendue": ("Polygon", "MultiPolygon", "LineString", "MultiLineString"),
    },
}

# Noms de colonnes susceptibles de porter la tension nominale
CANDIDATS_TENSION = [
    "tension", "tension_kv", "voltage", "kv", "niveau_tension",
    "classe_tension", "tension_nom",
]

CLE_LIMITES = "limites_admin"


# ----------------------------------------------------------------------------
def charger_emprise_territoriale():
    """Retourne l'union des limites administratives (EPSG cible) ou None."""
    chemin = CONFIG["sources_brutes"].get(CLE_LIMITES)
    if not chemin:
        print(f"[AVERT] clé '{CLE_LIMITES}' absente de config.yaml — pas de découpe.")
        return None

    p = ROOT / chemin
    if not p.exists():
        print(f"[AVERT] {p.name} introuvable — pas de découpe territoriale.")
        return None

    lim = gpd.read_file(p)
    if lim.crs is None:
        print(f"[AVERT] {p.name} sans CRS — découpe refusée par prudence.")
        return None

    lim = lim.to_crs(epsg=TARGET_EPSG)
    print(f"[INFO] Emprise de découpe : {p.name} ({len(lim)} entités)")
    return lim


def diagnostiquer(cle, gdf, chemin):
    """Diagnostic non destructif : CRS, géométrie, attributs, tension."""
    meta = METADONNEES[cle]

    print(f"\n--- {cle}  ({chemin.name}) ---")
    print(f"    entités        : {len(gdf):,}")
    print(f"    CRS source     : {gdf.crs}")
    print(f"    types géom.    : {dict(gdf.geom_type.value_counts())}")
    print(f"    colonnes       : {[c for c in gdf.columns if c != 'geometry']}")
    print(f"    source_donnee  : {meta['source_donnee']}")
    print(f"    réseau         : {meta['reseau']}")

    types_vus = set(gdf.geom_type.unique())
    if not types_vus & set(meta["geom_attendue"]):
        print(f"    [AVERT] type géométrique inattendu — attendu {meta['geom_attendue']}")

    if "NC" in meta["licence"]:
        print(f"    [RÉSERVE JURIDIQUE] licence {meta['licence']} — usage NON COMMERCIAL.")
        print(f"                        Autorisation écrite HQ requise pour la prestation.")

    cols_min = {c.lower(): c for c in gdf.columns}
    trouvee = next((cols_min[c] for c in CANDIDATS_TENSION if c in cols_min), None)
    if trouvee:
        print(f"    [OK] tension trouvée dans la colonne « {trouvee} »")
        print(f"         valeurs distinctes : {sorted(gdf[trouvee].dropna().unique())[:10]}")
    elif meta["reseau"] == "TRANSPORT":
        print(f"    [BLOQUANT] aucun attribut de tension.")
        print(f"               -> uti.t2h_elec_regles_degagement reste 'A_VALIDER'")
        print(f"               -> aucun buffer TRANSPORT ne peut être justifié.")

    return trouvee


def charger(cle, table, engine, emprise, inspect_only):
    chemin_rel = CONFIG["sources_brutes"].get(cle)
    if chemin_rel is None:
        print(f"\n[IGNORÉ] clé '{cle}' absente de sources_brutes dans config.yaml.")
        return False

    p = ROOT / chemin_rel
    if not p.exists():
        print(f"\n[IGNORÉ] {p.name} introuvable — déposer dans data/raw/ puis relancer.")
        return False

    gdf = gpd.read_file(p)

    if gdf.crs is None:
        raise ValueError(
            f"{p.name} n'a pas de CRS défini — reprojection impossible en confiance. "
            f"ATTENTION : EPSG:32188 et EPSG:2950 sont visuellement indiscernables "
            f"mais reposent sur des réalisations de datum différentes. Ne pas deviner."
        )

    diagnostiquer(cle, gdf, p)

    n0 = len(gdf)
    gdf = gdf[~gdf.geometry.isna() & ~gdf.geometry.is_empty].copy()
    if len(gdf) < n0:
        print(f"    [AVERT] {n0 - len(gdf)} géométrie(s) nulle(s) ou vide(s) écartée(s)")
    if gdf.empty:
        print(f"    [IGNORÉ] aucune géométrie exploitable.")
        return False

    gdf = gdf.to_crs(epsg=TARGET_EPSG)

    if emprise is not None:
        n1 = len(gdf)
        gdf = gpd.clip(gdf, emprise)
        gdf = gdf[~gdf.geometry.isna() & ~gdf.geometry.is_empty].copy()
        print(f"    découpe agglo  : {n1:,} -> {len(gdf):,} entités")
        if gdf.empty:
            print(f"    [IGNORÉ] aucune entité sur le territoire d'intervention.")
            return False

    gdf.columns = [c.lower() for c in gdf.columns]

    if inspect_only:
        print(f"    (mode --inspect : aucune écriture)")
        return True

    gdf.to_postgis(table, engine, schema="raw", if_exists="replace", index=False)

    with engine.begin() as conn:
        conn.execute(text(
            f'CREATE INDEX IF NOT EXISTS idx_raw_{table}_geom '
            f'ON raw."{table}" USING GIST (geometry);'
        ))

    print(f"    [OK] raw.{table} <- {p.name} ({len(gdf):,} entités, EPSG:{TARGET_EPSG})")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--no-clip", action="store_true",
                    help="ne pas découper sur les limites administratives")
    ap.add_argument("--inspect", action="store_true",
                    help="diagnostic seul, aucune écriture en base")
    args = ap.parse_args()

    print("=" * 74)
    print("01b_load_energie.py — couches sources UTI-T2H électrique")
    print("=" * 74)

    engine = None if args.inspect else get_engine()
    if engine is not None:
        with engine.begin() as conn:
            conn.execute(text("CREATE EXTENSION IF NOT EXISTS postgis"))
            conn.execute(text("CREATE SCHEMA IF NOT EXISTS raw"))
            conn.execute(text("CREATE SCHEMA IF NOT EXISTS uti"))

    emprise = None if args.no_clip else charger_emprise_territoriale()

    charges = 0
    for cle, table in TABLES_ENERGIE.items():
        if charger(cle, table, engine, emprise, args.inspect):
            charges += 1

    print("\n" + "=" * 74)
    print(f"Terminé — {charges}/{len(TABLES_ENERGIE)} couche(s) traitée(s).")
    print("=" * 74)
    print("\nRAPPELS AVANT 15_uti_hydroelectriques.sql :")
    print("  1. Tension nominale absente  -> buffers TRANSPORT non justifiables.")
    print("     Aucune source ouverte pour Montréal (entente HQ TransÉnergie requise).")
    print("  2. elec_emprises_hq = CC BY-NC 4.0 -> réserve juridique à lever.")
    print("  3. Aucune donnée de distribution dans le corpus. Les règles VALIDE")
    print("     (déboisement 5 / 6,5 m) de t2h_elec_regles_degagement sont orphelines.")
    print("  4. Zonage et rôle foncier : chargés séparément par 01c_load_zonage_foncier.py.")


if __name__ == "__main__":
    main()