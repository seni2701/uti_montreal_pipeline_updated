"""
01c_load_zonage_foncier.py
--------------------------
Chargement des couches nécessaires au DÉCOUPAGE EN SECTIONS du volet
hydroélectrique (UTI-T2H électrique, étape 4 du mandat) :

  - affectation_pum : affectation du sol PUM 2050 (règlement 24-017)
                      -> alimente t2h_elec_sections.zonage_affectation
  - role_foncier    : unités d'évaluation foncière (rôle)
                      -> alimente t2h_elec_sections.regime_foncier
                         et t2h_elec_rel_lots.proprietaire_type

Ces deux couches sont NÉCESSAIRES au mandat (lignes 114-118 : « chaque géométrie
de zonage doit constituer un tronçon » et « les propriétés privées doivent
constituer des sections distinctes »), mais ne DÉBLOQUENT rien tant que la
tension nominale est absente : les sections découpent les emprises, qui
n'existent pas encore. On charge maintenant pour être prêt le jour J.

Convention CARTHAB : 01_load_data.py n'est pas modifié. Script suffixé.

Usage :
    python scripts/01c_load_zonage_foncier.py --inspect   # colonnes réelles
    python scripts/01c_load_zonage_foncier.py             # chargement

Le mode --inspect est ESSENTIEL : les noms de colonnes réels diffèrent souvent
de la documentation (déjà constaté avec `affectatio` tronqué et limites_admin).
On ne code l'étape 4 qu'une fois ces noms connus.
"""

import argparse
from pathlib import Path

import geopandas as gpd
import yaml
from sqlalchemy import text

from utils.db import get_engine

ROOT = Path(__file__).resolve().parents[1]
CONFIG = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))
TARGET_EPSG = CONFIG["crs"]["target_epsg"]

SEP = "=" * 74

# ----------------------------------------------------------------------------
# Clé config -> table raw
# ----------------------------------------------------------------------------
TABLES = {
    "affectation_pum": "affectation_pum",
    "role_foncier":    "role_foncier",
}

# Colonnes candidates à repérer par introspection (on ne présume pas le nom)
CANDIDATS = {
    "affectation_pum": {
        "affectation": ["affectatio", "affectation", "affect", "categorie",
                        "usage", "typ_affect", "descriptio", "libelle"],
    },
    "role_foncier": {
        "usage":        ["utilisatio", "usage", "categorie", "cubf",
                         "code_utili", "usage_pred"],
        "proprietaire": ["nom_propri", "proprietai", "propriet", "nom_prop"],
        "matricule":    ["matricule", "id_uev", "no_lot", "id_provinc"],
        "adresse":      ["adresse", "no_civiq", "civique", "adresse_ci"],
    },
}

CLE_LIMITES = "limites_admin"


def charger_emprise():
    chemin = CONFIG["sources_brutes"].get(CLE_LIMITES)
    if not chemin:
        return None
    p = ROOT / chemin
    if not p.exists():
        print(f"[AVERT] {p.name} introuvable — pas de découpe.")
        return None
    lim = gpd.read_file(p)
    if lim.crs is None:
        print(f"[AVERT] {p.name} sans CRS — découpe refusée.")
        return None
    lim = lim.to_crs(epsg=TARGET_EPSG)
    print(f"[INFO] Emprise de découpe : {p.name} ({len(lim)} entités)")
    return lim


def introspecter(cle, gdf):
    """Repère les colonnes utiles par liste de candidats, sans présumer."""
    cols_min = {c.lower(): c for c in gdf.columns}
    resultats = {}
    print(f"    colonnes réelles : {[c for c in gdf.columns if c != 'geometry']}")
    for role, candidats in CANDIDATS[cle].items():
        trouvee = next((cols_min[c] for c in candidats if c in cols_min), None)
        if trouvee:
            n_distinct = gdf[trouvee].nunique(dropna=True)
            apercu = sorted(str(v) for v in gdf[trouvee].dropna().unique()[:8])
            print(f"    [{role:12}] -> « {trouvee} »  ({n_distinct} valeurs distinctes)")
            print(f"                    aperçu : {apercu}")
            resultats[role] = trouvee
        else:
            print(f"    [{role:12}] -> AUCUNE colonne reconnue parmi {candidats}")
    return resultats


def charger(cle, table, engine, emprise, inspect_only):
    chemin_rel = CONFIG["sources_brutes"].get(cle)
    if chemin_rel is None:
        print(f"\n[IGNORÉ] clé '{cle}' absente de config.yaml.")
        print(f"         Ajouter :  {cle}:  \"data/raw/<fichier>.shp\"")
        return False

    p = ROOT / chemin_rel
    if not p.exists():
        print(f"\n[IGNORÉ] {p.name} introuvable — déposer dans data/raw/ puis relancer.")
        return False

    print(f"\n--- {cle}  ({p.name}) ---")
    gdf = gpd.read_file(p)
    print(f"    entités        : {len(gdf):,}")
    print(f"    CRS source     : {gdf.crs}")
    print(f"    types géom.    : {dict(gdf.geom_type.value_counts())}")

    if gdf.crs is None:
        print(f"    [FAIL] CRS absent — reprojection impossible en confiance.")
        print(f"           32188 et 2950 sont indiscernables à l'œil. Ne pas deviner.")
        return False

    introspecter(cle, gdf)

    n0 = len(gdf)
    gdf = gdf[~gdf.geometry.isna() & ~gdf.geometry.is_empty].copy()
    if len(gdf) < n0:
        print(f"    [AVERT] {n0 - len(gdf)} géométrie(s) nulle(s) écartée(s)")
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
            print(f"    [IGNORÉ] aucune entité sur le territoire.")
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

    print(SEP)
    print("01c_load_zonage_foncier.py — zonage PUM 2050 + rôle foncier")
    print(SEP)

    engine = None if args.inspect else get_engine()
    if engine is not None:
        with engine.begin() as conn:
            conn.execute(text("CREATE EXTENSION IF NOT EXISTS postgis"))
            conn.execute(text("CREATE SCHEMA IF NOT EXISTS raw"))

    emprise = None if args.no_clip else charger_emprise()

    charges = 0
    for cle, table in TABLES.items():
        if charger(cle, table, engine, emprise, args.inspect):
            charges += 1

    print("\n" + SEP)
    print(f"Terminé — {charges}/{len(TABLES)} couche(s) traitée(s).")
    print(SEP)
    print("\nPROCHAINE ÉTAPE :")
    print("  Ces couches alimenteront t2h_elec_sections (étape 4 du mandat).")
    print("  Mais le découpage en sections découpe les EMPRISES, qui restent")
    print("  BLOQUÉES tant que la tension nominale est absente.")
    print("  -> Charger maintenant, appliquer après le déblocage HQ.")
    print("\n  Communiquer les noms de colonnes ci-dessus pour écrire 18/19/20.")


if __name__ == "__main__":
    main()
