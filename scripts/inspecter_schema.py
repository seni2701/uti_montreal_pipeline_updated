"""
inspecter_schema.py  -- JETABLE, a supprimer apres usage.
Lit .env (variables DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASS) et liste
toutes les tables du schema uti avec leurs colonnes et types geometriques.

Usage (depuis la racine du projet, ou .env est present) :
    conda activate uti-montreal
    python scripts/inspecter_schema.py

Ne modifie RIEN : uniquement des SELECT sur les catalogues systeme.
"""

import os
from sqlalchemy import create_engine, text


def charger_env():
    """Charge .env (dotenv si dispo, sinon parse minimal)."""
    try:
        from dotenv import load_dotenv
        load_dotenv()
    except Exception:
        pass
    if os.path.exists(".env"):
        for ligne in open(".env", encoding="utf-8-sig"):
            ligne = ligne.strip()
            if ligne and not ligne.startswith("#") and "=" in ligne:
                cle, val = ligne.split("=", 1)
                os.environ.setdefault(cle.strip(), val.strip().strip('"').strip("'"))


def construire_url():
    """Construit l'URL a partir des variables DB_* du projet (avec repli PG*)."""
    host = os.environ.get("DB_HOST") or os.environ.get("PGHOST") or "localhost"
    port = os.environ.get("DB_PORT") or os.environ.get("PGPORT") or "5432"
    name = os.environ.get("DB_NAME") or os.environ.get("PGDATABASE") or "uti_montreal"
    user = os.environ.get("DB_USER") or os.environ.get("PGUSER") or "ndoune"
    pwd = os.environ.get("DB_PASS") or os.environ.get("PGPASSWORD") or ""
    return f"postgresql+psycopg2://{user}:{pwd}@{host}:{port}/{name}", f"{host}:{port}/{name}"


def main():
    charger_env()
    url, apercu = construire_url()
    print(f"[connexion] cible = {apercu}\n")

    engine = create_engine(url)

    q_tables = text("""
        SELECT table_name,
               string_agg(column_name, ', ' ORDER BY ordinal_position) AS colonnes
        FROM information_schema.columns
        WHERE table_schema = 'uti'
        GROUP BY table_name
        ORDER BY table_name;
    """)
    q_geom = text("""
        SELECT f_table_name, type, srid
        FROM geometry_columns
        WHERE f_table_schema = 'uti'
        ORDER BY f_table_name;
    """)

    with engine.connect() as cx:
        print("========== TABLES DU SCHEMA uti (avec colonnes) ==========")
        for r in cx.execute(q_tables):
            print(f"\n### {r[0]}\n    {r[1]}")
        print("\n\n========== TYPES GEOMETRIQUES (geometry_columns) ==========")
        for r in cx.execute(q_geom):
            print(f"  {r[0]:<34} | {r[1]:<15} | SRID {r[2]}")


if __name__ == "__main__":
    main()