"""
01_load_data.py
Charge les couches sources (data/raw/) dans le schéma `raw` de PostGIS,
en reprojetant systématiquement vers EPSG:2950 (cf. config.yaml).

Usage :
    python scripts/01_load_data.py

Alternative ogr2ogr (plus rapide sur de gros fichiers) :
    ogr2ogr -f PostgreSQL PG:"host=localhost dbname=uti_montreal user=ndoune password=changer_moi" \
        data/raw/cadastre_mtl.shp -nln raw.cadastre -t_srs EPSG:2950 -overwrite -lco GEOMETRY_NAME=geom
"""
import yaml
import geopandas as gpd
from pathlib import Path
from sqlalchemy import text
from utils.db import get_engine

ROOT = Path(__file__).resolve().parents[1]
CONFIG = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8"))
TARGET_EPSG = CONFIG["crs"]["target_epsg"]

# Correspondance clé config → nom de table dans le schéma raw.
# Les clés doivent exister dans sources_brutes du config.yaml.
TABLES = {
    # --- Livrable A : UTI Routières ---
    "cadastre":           "cadastre",
    "reseau_routier":     "reseau_routier",
    "reseau_cyclable":    "reseau_cyclable",
    "voirie_active":      "voirie_active",
    "poles":              "poles",
    "ruelles_vertes":     "ruelles_vertes",
    "conditions_ruelles": "conditions_ruelles",
    "troncon":            "troncon",
    "adresses":           "adresses",
    "arbres_publics":     "arbres_publics",
    "batiments":          "batiments",
    "zonage":             "zonage",
    "limites_admin":      "limites_admin",
    "collisions_routieres": "collisions_routieres",
    "signalisation_stationnement": "signalisation_stationnement",
    "chantier_routier":    "chantier_routier",
    
    # --- Livrable B : UTI Hydriques ---
    "hydro_cours_eau":       "hydro_cours_eau",
    "hydro_milieux_humides": "hydro_milieux_humides",
    "hydro_rives":           "hydro_rives",

    # --- Livrable C : Infrastructures ferroviaires ---
    "ferro_lignes":       "ferro_lignes",
    "ferro_gares":        "ferro_gares",
    "ferro_cours_triage": "ferro_cours_triage",

    # --- Livrable D : Infrastructures énergétiques ---
    "energie_lignes_ht":     "energie_lignes_ht",
    "energie_postes":        "energie_postes",
    "energie_gazoducs":      "energie_gazoducs",
    "energie_installations": "energie_installations",
}


def init_db(engine):
    """Crée les schémas et active PostGIS si nécessaire — idempotent."""
    with engine.begin() as conn:
        conn.execute(text("CREATE EXTENSION IF NOT EXISTS postgis"))
        conn.execute(text("CREATE SCHEMA IF NOT EXISTS raw"))
        conn.execute(text("CREATE SCHEMA IF NOT EXISTS uti"))
    print("[ok] schémas raw + uti vérifiés / créés, PostGIS activé")


def load_layer(key: str, table: str, engine):
    # Lecture depuis la bonne clé du config
    raw_path = CONFIG["sources_brutes"].get(key)
    if raw_path is None:
        print(f"[ignoré] clé '{key}' absente de sources_brutes dans config.yaml.")
        return

    path = ROOT / raw_path
    if not path.exists():
        print(f"[ignoré] {path.name} introuvable — déposer le fichier dans data/raw/ puis relancer.")
        return

    gdf = gpd.read_file(path)

    if gdf.crs is None:
        raise ValueError(
            f"{path.name} n'a pas de CRS défini — impossible de reprojeter en confiance."
        )

    # Supprimer les géométries nulles ou vides avant insertion
    n_avant = len(gdf)
    gdf = gdf[~gdf.geometry.isna() & ~gdf.geometry.is_empty].copy()
    n_apres = len(gdf)
    if n_apres == 0:
        print(f"[ignoré] {path.name} — aucune géométrie valide ({n_avant} entités nulles).")
        print(f"         → Re-télécharger ce fichier depuis les données ouvertes de Montréal.")
        return
    if n_apres < n_avant:
        print(f"[avertissement] {path.name} — {n_avant - n_apres} géométries nulles supprimées.")

    gdf = gdf.to_crs(epsg=TARGET_EPSG)
    gdf.columns = [c.lower() for c in gdf.columns]

    gdf.to_postgis(table, engine, schema="raw", if_exists="replace", index=False)
    print(f"[ok] raw.{table} <- {path.name} ({n_apres} entités, EPSG:{TARGET_EPSG})")


def main():
    engine = get_engine()
    init_db(engine)
    for key, table in TABLES.items():
        load_layer(key, table, engine)


if __name__ == "__main__":
    main()