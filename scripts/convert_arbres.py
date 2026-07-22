#!/usr/bin/env python
# -*- coding: utf-8 -*-
# =============================================================================
#  diag_comptages.py
#  ---------------------------------------------------------------------------
#  Verifie que les comptages spatiaux (nb_arbres, nb_chantiers, et autres
#  colonnes de presence) de la couche maitresse sont REELLEMENT peuples et non
#  systematiquement a zero. Repere aussi des emplacements a valeur non nulle
#  pour inspection dans QGIS.
#
#  Lecture seule. SQL execute via SQLAlchemy (jamais psql en PowerShell).
#  Execution :  python diag_comptages.py
# =============================================================================

import os
from sqlalchemy import create_engine, text, URL

# Table a diagnostiquer et colonnes de comptage a examiner.
TABLE = 'uti.couche_maitresse'
COL_COUNT = ["nb_arbres", "nb_chantiers"]
COL_BOOL  = ["a_piste_cyclable", "a_reseau_cyclable", "a_ruelle_verte"]
# Sources ponctuelles pour comparer la couverture (schema, table).
SOURCES_ARBRES    = ("uti", "arbres")
SOURCES_CHANTIERS = ("raw", "chantier_routier")
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


def _fmt(n):
    return f"{n:,}".replace(",", " ")


def diag_count(conn, col, source=None):
    r = conn.execute(text(f"""
        SELECT count(*) AS n_total,
               count(*) FILTER (WHERE "{col}" > 0) AS n_positifs,
               COALESCE(sum("{col}"), 0) AS somme,
               COALESCE(max("{col}"), 0) AS maxi
        FROM {TABLE}
    """)).fetchone()
    if not r:
        return
    n_total, n_pos, somme, maxi = r[0], r[1], r[2], r[3]
    pct = (n_pos / n_total * 100) if n_total else 0
    print(f"\n[{col}]")
    print(f"  emplacements                 : {_fmt(n_total)}")
    print(f"  avec {col} > 0        : {_fmt(n_pos)} ({pct:.1f} %)")
    print(f"  somme / maximum              : {_fmt(somme)} / {_fmt(maxi)}")

    if source:
        try:
            n_src = conn.execute(text(
                f'SELECT count(*) FROM "{source[0]}"."{source[1]}"')).scalar() or 0
            print(f"  total dans la source {source[0]}.{source[1]:16s}: {_fmt(n_src)}")
            if somme and n_src:
                print(f"  -> {somme/n_src*100:.1f} % des entites source "
                      f"tombent dans un emplacement")
        except Exception as e:
            print(f"  (source {source} illisible : {e})")

    if n_pos:
        print("  exemples (valeurs les plus elevees) :")
        for row in conn.execute(text(f"""
            SELECT id_emplacement, COALESCE(nom_rue,'?') AS rue,
                   COALESCE(arr_appartenance,'?') AS arr, "{col}" AS v
            FROM {TABLE} WHERE "{col}" > 0
            ORDER BY "{col}" DESC LIMIT 5
        """)):
            print(f"    id={row[0]:>7}  {col}={row[3]:>4}  "
                  f"{row[2]} — {row[1]}")
    else:
        print("  Aucun emplacement > 0 : verifier l'appariement spatial "
              "(SRID, geometrie source, parterres trop minces).")


def diag_bool(conn, col):
    try:
        n = conn.execute(text(
            f'SELECT count(*) FILTER (WHERE "{col}") FROM {TABLE}')).scalar() or 0
        print(f"  {col:22s}: {_fmt(n)} emplacements = vrai")
    except Exception:
        print(f"  {col:22s}: colonne absente")


def main():
    print("=" * 64)
    print(f"  Diagnostic des comptages — {TABLE}")
    print("=" * 64)
    engine = creer_engine()
    with engine.connect() as conn:
        diag_count(conn, "nb_arbres", SOURCES_ARBRES)
        diag_count(conn, "nb_chantiers", SOURCES_CHANTIERS)
        print("\n[Presences booleennes]")
        for c in COL_BOOL:
            diag_bool(conn, c)
    print("\nRappel : nb_chantiers est normalement 0 quasi partout "
          "(peu de chantiers dans la source). nb_arbres > 0 est attendu "
          "sur les rues bordees d'arbres, 0 sur bretelles/pistes.")


if __name__ == "__main__":
    main()
