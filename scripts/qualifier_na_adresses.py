"""
qualifier_na_adresses.py  -- LECTURE SEULE. Etablit les faits avant correction :
  1) Rues-limites N/A : bordure de territoire legitime vs rattachement echoue
  2) Adresses : perimetre exact du geocodage partiel et du code_postal
Reutilise la connexion .env. Ne modifie RIEN.

Usage (racine du projet) :
    python scripts/qualifier_na_adresses.py
"""

import os
from sqlalchemy import create_engine, text


def env():
    try:
        from dotenv import load_dotenv
        load_dotenv()
    except Exception:
        pass
    if os.path.exists(".env"):
        for l in open(".env", encoding="utf-8-sig"):
            l = l.strip()
            if l and not l.startswith("#") and "=" in l:
                k, v = l.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def url():
    return (f"postgresql+psycopg2://{os.environ.get('DB_USER','ndoune')}:"
            f"{os.environ.get('DB_PASS','')}@{os.environ.get('DB_HOST','localhost')}:"
            f"{os.environ.get('DB_PORT','5432')}/{os.environ.get('DB_NAME','uti_montreal')}")


def show(cx, titre, sql):
    print(f"\n{'='*68}\n{titre}\n{'-'*68}")
    for r in cx.execute(text(sql)):
        print("  " + " | ".join(str(x) for x in r))


def main():
    env()
    with create_engine(url()).connect() as cx:

        print("\n#### POINT 1 -- RUES-LIMITES N/A ####")

        show(cx, "[1a] Ventilation des 355 rues-limites",
             """SELECT
                  count(*)                                                   AS total,
                  count(*) FILTER (WHERE arr_gch = 'N/A' OR arr_drt = 'N/A') AS avec_na,
                  count(*) FILTER (WHERE arr_gch <> 'N/A' AND arr_drt <> 'N/A'
                                    AND arr_gch <> arr_drt)                  AS vraies_limites_utg
                FROM uti.v_rues_limites_utg;""")

        # La table de base derriere la vue = troncons_polygones (arr_gch/arr_drt).
        # On teste si un cote N/A pourrait etre re-rattache a une UTG par jointure
        # spatiale : combien de troncons a cote N/A INTERSECTENT quand meme une UTG ?
        # NB : suppose une table de polygones UTG. On tente les noms plausibles ;
        # si aucun ne matche, la requete [1c] echouera -> me le signaler.
        show(cx, "[1b] Troncons avec un cote arr = 'N/A' (source du N/A)",
             """SELECT
                  count(*) FILTER (WHERE arr_gch = 'N/A') AS gch_na,
                  count(*) FILTER (WHERE arr_drt = 'N/A') AS drt_na,
                  count(*) FILTER (WHERE arr_gch = 'N/A' AND arr_drt = 'N/A') AS deux_na
                FROM uti.troncons_polygones;""")

        show(cx, "[1c] Exemples de troncons a cote N/A (pour inspection)",
             """SELECT id_trc, nom_rue, arr_gch, arr_drt
                FROM uti.troncons_polygones
                WHERE arr_gch = 'N/A' OR arr_drt = 'N/A'
                ORDER BY nom_rue LIMIT 15;""")

        print("\n\n#### POINT 2 -- ADRESSES ####")

        show(cx, "[2a] Perimetre du geocodage",
             """SELECT
                  count(*)                                    AS total_troncons,
                  count(*) FILTER (WHERE nb_adresses > 0)      AS avec_adresse,
                  count(*) FILTER (WHERE nb_adresses = 0)      AS sans_adresse,
                  count(*) FILTER (WHERE code_postal IS NOT NULL) AS avec_code_postal
                FROM uti.troncons_adresses;""")

        show(cx, "[2b] La table adresses_troncon contient-elle du code postal exploitable ?",
             """SELECT
                  count(*)                                       AS total_adresses,
                  count(*) FILTER (WHERE texte IS NOT NULL)       AS avec_texte,
                  min(id_trc) AS id_trc_min, max(id_trc) AS id_trc_max
                FROM uti.adresses_troncon;""")

        show(cx, "[2c] Echantillon d'adresses (voir si un code postal s'y cache)",
             """SELECT id_adresse, texte, id_trc, dist_m
                FROM uti.adresses_troncon
                WHERE texte IS NOT NULL
                ORDER BY id_adresse LIMIT 10;""")


if __name__ == "__main__":
    main()
