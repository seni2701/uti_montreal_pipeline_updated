"""
17_export_gpkg_livrable_D.py
---------------------------
Export V11.3 : PAIR / IMPAIR sans coupures avec zonage spatial.

Colonnes rétablies :
- id_troncon : liste des tronçons de la ligne;
- nb_lots : nombre de lots associés.
"""

import argparse
import sys
from pathlib import Path

import geopandas as gpd
import yaml

from utils.db import get_engine


ROOT = Path(__file__).resolve().parents[1]
CONFIG = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))
EPSG = CONFIG["crs"]["target_epsg"]

DEFAUT_SORTIE = CONFIG.get("sorties", {}).get(
    "uti_hydroelectriques_gpkg",
    "data/processed/UTI_Hydroelectriques.gpkg",
)

SQL = """
SELECT
    id_emprise,
    id_ligne,
    id_troncon,
    emplacement,
    reseau,
    exploitant,
    tension_kv,
    largeur_buffer_m,
    largeur_emprise_totale_m,
    longueur_ligne_sol_m,
    nb_troncons,
    longueur_troncons_totale_m,
    premier_id_troncon,
    dernier_id_troncon,
    numeros_lots,
    nb_lots,
    regime_foncier,
    statut_cadastre,
    zonage_affectation,
    nb_zonages,
    surface_m2,
    emprise_sol_m2,
    empreinte_ligne_sol_m2,
    hauteur_ligne_m,
    hauteur_vegetation_max_m,
    emprise_chute_m2,
    geom_ligne_wkt,
    methode_geometrie,
    geom
FROM uti.couche_livrable_t2h_maitresse
ORDER BY id_ligne, emplacement
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sortie",
        default=DEFAUT_SORTIE,
        help=f"Chemin du GeoPackage, défaut : {DEFAUT_SORTIE}",
    )
    args = parser.parse_args()

    gpkg = ROOT / args.sortie
    gpkg.parent.mkdir(parents=True, exist_ok=True)

    if gpkg.exists():
        try:
            gpkg.unlink()
        except PermissionError:
            print(f"[ÉCHEC] {gpkg.name} est ouvert dans QGIS.")
            print("Fermer complètement QGIS, puis relancer.")
            sys.exit(1)

    engine = get_engine()

    try:
        gdf = gpd.read_postgis(
            SQL,
            engine,
            geom_col="geom",
        )
    except Exception as exc:
        print("[ÉCHEC] La couche maîtresse est indisponible.")
        print(
            "Exécuter : "
            "python scripts/02_run_sql_pipeline.py --only 24"
        )
        print(f"Détail : {type(exc).__name__}: {exc}")
        sys.exit(1)
    finally:
        engine.dispose()

    if gdf.empty:
        print("[ÉCHEC] La couche maîtresse est vide.")
        sys.exit(1)

    if gdf.crs is None:
        gdf = gdf.set_crs(epsg=EPSG)

    controles = (
        gdf.groupby("id_ligne")["emplacement"]
        .agg(lambda x: set(x.dropna()))
    )
    anomalies = controles[controles != {"PAIR", "IMPAIR"}]

    if not anomalies.empty:
        print(
            f"[ÉCHEC] {len(anomalies)} ligne(s) n'ont pas "
            "exactement PAIR et IMPAIR."
        )
        sys.exit(1)

    gdf.to_file(
        gpkg,
        driver="GPKG",
        layer="UTI_Hydroelectriques_Maitresse",
        index=False,
    )

    print("=" * 72)
    print("LIVRABLE D — V11.3 AVEC ZONAGE SPATIAL")
    print("=" * 72)
    print(f"Fichier : {gpkg}")
    print("Couche  : UTI_Hydroelectriques_Maitresse")
    print(f"Entités : {len(gdf):,}")
    print(f"Lignes  : {gdf['id_ligne'].nunique():,}")
    print("")
    print("Emplacements :")
    print(gdf["emplacement"].value_counts().to_string())
    print("")
    print("Entités avec tronçons :")
    print(f"{gdf['id_troncon'].notna().sum():,} / {len(gdf):,}")
    print("")
    print("Entités avec lots :")
    print(f"{(gdf['nb_lots'] > 0).sum():,} / {len(gdf):,}")
    print("")
    print("Entités avec zonage :")
    print(f"{(gdf['nb_zonages'] > 0).sum():,} / {len(gdf):,}")


if __name__ == "__main__":
    main()