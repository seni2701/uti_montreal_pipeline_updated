#!/usr/bin/env python
# -*- coding: utf-8 -*-
# =============================================================================
#  inspect_couches_reference.py
#  ---------------------------------------------------------------------------
#  Confirme, AVANT de brancher l'enrichissement, l'etat reel des couches de
#  reference (reseau cyclable, ruelles vertes, zonage, chantiers, interferences,
#  arbres, voirie) dans les schemas 'raw' et 'uti' :
#     - schema et nom exacts de la table
#     - colonne geometrique, SRID declare, type de geometrie
#     - nombre d'entites et nombre de geometries INVALIDES
#
#  But : ne rien presumer. Le SRID conditionne l'enrichissement spatial
#  (reprojection vers EPSG:2950) ; la validite conditionne ST_Intersects /
#  ST_Contains. Ce script ne modifie RIEN (lecture seule).
#
#  SQL execute via SQLAlchemy (jamais psql en PowerShell).
#  Execution :  python inspect_couches_reference.py
# =============================================================================

import os
from sqlalchemy import create_engine, text, URL

SRID_CIBLE = 2950
SCHEMAS = ["raw", "uti"]
# Motifs de noms de couches de reference a inspecter.
MOTIFS = ["cycl", "ruelle", "zon", "chantier", "interf", "arbre", "voirie"]
_RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _charger_dotenv():
    try:
        from dotenv import load_dotenv
        for c in (os.path.join(_RACINE, ".env"), ".env"):
            if os.path.exists(c):
                load_dotenv(c)
        return
    except Exception:
        pass
    for c in (os.path.join(_RACINE, ".env"), ".env"):
        if os.path.exists(c):
            with open(c, encoding="utf-8") as f:
                for ligne in f:
                    ligne = ligne.strip()
                    if ligne and not ligne.startswith("#") and "=" in ligne:
                        k, v = ligne.split("=", 1)
                        os.environ.setdefault(k.strip(),
                                              v.strip().strip('"').strip("'"))


def _p(*keys, default=None):
    for k in keys:
        if os.environ.get(k):
            return os.environ[k]
    return default


def creer_engine():
    _charger_dotenv()
    for k in ("DATABASE_URL", "SQLALCHEMY_DATABASE_URI", "DB_URL"):
        if os.environ.get(k):
            return create_engine(os.environ[k], future=True,
                                 connect_args={"gssencmode": "disable"})
    pwd = _p("PGPASSWORD", "POSTGRES_PASSWORD", "DB_PASSWORD", "DB_PASS")
    if not pwd:
        raise SystemExit("Aucun mot de passe : definir $env:PGPASSWORD ou .env")
    url = URL.create(
        "postgresql+psycopg2",
        username=_p("PGUSER", "POSTGRES_USER", "DB_USER", default="ndoune"),
        password=pwd,
        host=_p("PGHOST", "POSTGRES_HOST", "DB_HOST", default="localhost"),
        port=int(_p("PGPORT", "POSTGRES_PORT", "DB_PORT", default="5432") or 5432),
        database=_p("PGDATABASE", "POSTGRES_DB", "DB_NAME", default="uti_montreal"),
    )
    return create_engine(url, future=True, connect_args={"gssencmode": "disable"})


def main():
    like = " OR ".join(f"f_table_name ILIKE '%{m}%'" for m in MOTIFS)
    engine = creer_engine()
    with engine.connect() as conn:
        rows = conn.execute(text(f"""
            SELECT f_table_schema, f_table_name, f_geometry_column, srid, type
            FROM geometry_columns
            WHERE f_table_schema = ANY(:schemas) AND ({like})
            ORDER BY f_table_schema, f_table_name
        """), {"schemas": SCHEMAS}).fetchall()

        if not rows:
            print("Aucune couche de reference trouvee dans", SCHEMAS)
            print("(les tables existent peut-etre sans geometrie enregistree "
                  "dans geometry_columns — verifier information_schema.columns)")
            return

        print(f"{'schema.table':40s} {'geom':10s} {'srid':>6s} "
              f"{'type':16s} {'entites':>10s} {'invalides':>10s}")
        print("-" * 96)
        for sch, tbl, gcol, srid, gtype in rows:
            try:
                r = conn.execute(text(
                    f'SELECT count(*), '
                    f'count(*) FILTER (WHERE NOT ST_IsValid("{gcol}")) '
                    f'FROM "{sch}"."{tbl}"'
                )).fetchone()
                n, ninv = (r[0], r[1]) if r else (0, 0)
            except Exception as e:
                n, ninv = -1, -1
                print(f"  (erreur lecture {sch}.{tbl}: {e})")
            drapeau = ""
            if srid not in (SRID_CIBLE, None):
                drapeau += f"  <- reprojeter depuis {srid}"
            if srid in (0, None):
                drapeau += "  <- SRID absent (a corriger avant usage)"
            if ninv and ninv > 0:
                drapeau += f"  <- {ninv} geometries invalides (ST_MakeValid)"
            print(f"{sch+'.'+tbl:40s} {gcol:10s} {str(srid):>6s} "
                  f"{str(gtype):16s} {n:>10,} {ninv:>10,}".replace(",", " ")
                  + drapeau)

        print("\nRappel : le SRID cible du pipeline est EPSG:"
              f"{SRID_CIBLE}. Le script d'enrichissement reprojette a la volee "
              "les couches dont le SRID differe ; en revanche un SRID absent (0) "
              "ou des geometries invalides doivent etre corriges a la source.")


if __name__ == "__main__":
    main()