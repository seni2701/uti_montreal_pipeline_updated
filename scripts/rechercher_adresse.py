#!/usr/bin/env python
# -*- coding: utf-8 -*-
# =============================================================================
#  rechercher_adresse.py
#  ---------------------------------------------------------------------------
#  Recherche un emplacement (parterre) a partir d'une adresse : rue + numero
#  civique. Met en oeuvre le repere de recherche du mandat (Etape B) :
#      adresse saisie  ->  parite (pair/impair)  ->  plage civique  ->  tronçon
#
#  Logique : nom_rue (ILIKE) + cote (parite du numero) + numero dans la plage
#  civique du cote (plage_civique). Repli : correspondance dans le texte
#  detaille 'adresses' si la plage ne couvre pas le numero.
#
#  Lecture seule. SQL execute via SQLAlchemy (jamais psql en PowerShell).
#  Usage :
#      python rechercher_adresse.py "De Champlain" 1732
#      python rechercher_adresse.py            (mode interactif)
# =============================================================================

import os
import sys
from sqlalchemy import create_engine, text, URL

TABLE = "uti.couche_maitresse_livrable"   # couche livrable a interroger
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


# Requete principale : rue + parite + numero dans la plage civique du cote.
SQL_PLAGE = text(f"""
    SELECT id_emplacement, id_treevans, id_troncon, cote, nom_rue,
           plage_civique, arr_appartenance, adresses,
           round(ST_X(ST_Centroid(geom))::numeric, 1) AS x,
           round(ST_Y(ST_Centroid(geom))::numeric, 1) AS y
    FROM {TABLE}
    WHERE nom_rue ILIKE '%' || :rue || '%'
      AND cote = CASE WHEN (:no)::int % 2 = 0 THEN 'pair' ELSE 'impair' END
      AND plage_civique ~ '^[0-9]+-[0-9]+$'
      AND (:no)::int BETWEEN
              LEAST(split_part(plage_civique, '-', 1)::int,
                    split_part(plage_civique, '-', 2)::int)
          AND GREATEST(split_part(plage_civique, '-', 1)::int,
                       split_part(plage_civique, '-', 2)::int)
    ORDER BY nom_rue, id_troncon
""")

# Repli : le numero apparait dans le texte detaille des adresses du tronçon.
SQL_TEXTE = text(f"""
    SELECT id_emplacement, id_treevans, id_troncon, cote, nom_rue,
           plage_civique, arr_appartenance, adresses,
           round(ST_X(ST_Centroid(geom))::numeric, 1) AS x,
           round(ST_Y(ST_Centroid(geom))::numeric, 1) AS y
    FROM {TABLE}
    WHERE nom_rue ILIKE '%' || :rue || '%'
      AND cote = CASE WHEN (:no)::int % 2 = 0 THEN 'pair' ELSE 'impair' END
      AND adresses ILIKE '%' || :no || '%'
    ORDER BY nom_rue, id_troncon
""")


def rechercher(conn, rue, numero):
    params = {"rue": rue, "no": str(numero)}
    lignes = conn.execute(SQL_PLAGE, params).mappings().all()
    methode = "plage civique"
    if not lignes:
        lignes = conn.execute(SQL_TEXTE, params).mappings().all()
        methode = "texte adresses (repli)"
    return lignes, methode


def afficher(rue, numero, lignes, methode):
    parite = "pair" if int(numero) % 2 == 0 else "impair"
    print(f"\nRecherche : {numero} (cote {parite}), rue ~ '{rue}'")
    if not lignes:
        print("  Aucun emplacement trouve.")
        print("  Pistes : verifier l'orthographe de la rue, essayer un extrait "
              "plus court, ou l'adresse peut relever d'un tronçon non geocode "
              "(autoroute, parc...).")
        return
    print(f"  {len(lignes)} emplacement(s) trouve(s) (methode : {methode}) :")
    for r in lignes:
        print(f"  ┌ id_emplacement {r['id_emplacement']}  "
              f"({r['id_treevans'] or 'sans id_treevans'})")
        print(f"  │ {r['nom_rue']} — cote {r['cote']} — plage {r['plage_civique']}")
        print(f"  │ tronçon {r['id_troncon']} — {r['arr_appartenance']}")
        print(f"  │ centre (EPSG:2950)  X={r['x']}  Y={r['y']}  "
              f"(QGIS : coller dans la barre 'Coordonnee' pour zoomer)")
        adr = (r['adresses'] or "")[:90]
        print(f"  └ adresses : {adr}{'…' if r['adresses'] and len(r['adresses']) > 90 else ''}")


def main():
    if len(sys.argv) >= 3:
        rue, numero = sys.argv[1], sys.argv[2]
    else:
        rue = input("Rue (ex. De Champlain) : ").strip()
        numero = input("Numero civique (ex. 1732) : ").strip()
    if not rue or not numero.isdigit():
        raise SystemExit("Usage : python rechercher_adresse.py \"<rue>\" <numero>")
    engine = creer_engine()
    with engine.connect() as conn:
        lignes, methode = rechercher(conn, rue, numero)
    afficher(rue, numero, lignes, methode)


if __name__ == "__main__":
    main()
