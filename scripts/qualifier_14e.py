"""
qualifier_14e.py  -- LECTURE SEULE. Imprime les resultats de qualification
des points 2 (troncons nb_adresses=0) et 3 (interferences sans id_trc),
car le runner SQL n'affiche pas les SELECT. Reutilise la connexion .env.

Usage (racine du projet) :
    conda activate uti-montreal
    python scripts\qualifier_14e.py

Ne modifie RIEN.
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

        print("\n#### POINT 3 -- INTERFERENCES SANS id_trc (3 255) ####")

        show(cx, "[3a] Repartition par distance au troncon le plus proche",
             """SELECT
                  CASE
                    WHEN d IS NULL THEN 'aucun troncon < 50 m (vide legitime)'
                    WHEN d <= 15   THEN 'a) <= 15 m (RATE probable : dans le rayon)'
                    WHEN d <= 30   THEN 'b) 15-30 m (limite)'
                    ELSE                'c) 30-50 m (probablement legitime)'
                  END AS tranche, count(*) AS n
                FROM (
                  SELECT i.id_interf,
                         (SELECT min(ST_Distance(i.geom, t.geom))
                          FROM uti.troncons_polygones t
                          WHERE ST_DWithin(i.geom, t.geom, 50)) AS d
                  FROM uti.interferences_troncon i
                  WHERE i.id_trc IS NULL AND i.categorie <> 'chantier'
                ) s
                GROUP BY tranche ORDER BY tranche;""")

        show(cx, "[3b] Ventilation par categorie",
             """SELECT categorie, count(*) AS n_sans_id_trc
                FROM uti.interferences_troncon
                WHERE id_trc IS NULL AND categorie <> 'chantier'
                GROUP BY categorie ORDER BY n_sans_id_trc DESC;""")

        print("\n\n#### POINT 2 -- TRONCONS nb_adresses=0 AVEC PLAGE (5 018) ####")

        show(cx, "[2a] Croisement plage civique x presence de geocodage",
             """SELECT
                  CASE WHEN taux_geocodage IS NULL THEN 'sans geocodage (candidat rate)'
                       ELSE 'avec geocodage' END AS etat, count(*) AS n
                FROM uti.troncons_adresses
                WHERE nb_adresses = 0
                  AND (COALESCE(deb_gch,0)<>0 OR COALESCE(fin_gch,0)<>0
                    OR COALESCE(deb_drt,0)<>0 OR COALESCE(fin_drt,0)<>0)
                GROUP BY etat ORDER BY n DESC;""")

        show(cx, "[2b] Echantillon de 20 cas (inspection type Beausejour)",
             """SELECT id_trc, nom_rue, deb_gch, fin_gch, deb_drt, fin_drt, taux_geocodage
                FROM uti.troncons_adresses
                WHERE nb_adresses = 0
                  AND (COALESCE(deb_gch,0)<>0 OR COALESCE(fin_gch,0)<>0
                    OR COALESCE(deb_drt,0)<>0 OR COALESCE(fin_drt,0)<>0)
                ORDER BY id_trc LIMIT 20;""")

        print("\n\n#### CONTROLE 14d -- ARBRES HORS EMPRISE APRES CORRECTION ####")
        show(cx, "[14d] Etat des arbres traites",
             """SELECT
                  count(*) FILTER (WHERE geom_source IS NOT NULL) AS traites,
                  count(*) FILTER (WHERE hors_emprise)            AS restants_aberrants
                FROM uti.arbres;""")


if __name__ == "__main__":
    main()
