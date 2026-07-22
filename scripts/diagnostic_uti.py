"""
diagnostic_uti.py  -- LECTURE SEULE. Remplace 14a pour l'ETAPE DE LECTURE,
car le runner SQL n'affiche pas les resultats des SELECT.
Reutilise la connexion .env (DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASS).

Usage (racine du projet) :
    conda activate uti-montreal
    python scripts/diagnostic_uti.py

Ne modifie RIEN. Sort : audit SRID, gate cause racine [C], invariant, F1-F4.
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
    h = os.environ.get("DB_HOST", "localhost"); p = os.environ.get("DB_PORT", "5432")
    n = os.environ.get("DB_NAME", "uti_montreal"); u = os.environ.get("DB_USER", "ndoune")
    w = os.environ.get("DB_PASS", "")
    return f"postgresql+psycopg2://{u}:{w}@{h}:{p}/{n}"


def show(cx, titre, sql):
    print(f"\n{'='*68}\n{titre}\n{'-'*68}")
    for r in cx.execute(text(sql)):
        print("  " + " | ".join(str(x) for x in r))


def main():
    env()
    eng = create_engine(url())
    with eng.connect() as cx:

        show(cx, "[S] AUDIT SRID -- toute table a SRID 0 est a corriger",
             """SELECT f_table_name, f_geometry_column, type, srid
                FROM geometry_columns WHERE f_table_schema='uti' ORDER BY srid, f_table_name;""")

        show(cx, "[S2] EMPRISE des parterres (SRID 0) -- declarable en 2950 si dans MTM8",
             """SELECT round(ST_XMin(ST_Extent(geom))::numeric,1),
                       round(ST_XMax(ST_Extent(geom))::numeric,1),
                       round(ST_YMin(ST_Extent(geom))::numeric,1),
                       round(ST_YMax(ST_Extent(geom))::numeric,1)
                FROM uti.parterres;""")
        print("   Attendu MTM8 : X ~266000-306500 | Y ~5029000-5062700")

        show(cx, "[A] INVENTAIRE DES INVALIDITES par couche",
             """SELECT 'rues_polygones', count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.rues_polygones
                UNION ALL SELECT 'rues_polygones_enrichies', count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.rues_polygones_enrichies
                UNION ALL SELECT 'troncons_polygones', count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.troncons_polygones
                UNION ALL SELECT 'parterres', count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.parterres
                UNION ALL SELECT 'terre_pleins', count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.terre_pleins
                UNION ALL SELECT 'composantes_voirie', count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.composantes_voirie
                UNION ALL SELECT 'interferences_troncon', count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.interferences_troncon
                ORDER BY 3 DESC;""")

        print(f"\n{'#'*68}\n#  [C] GATE CAUSE RACINE -- LE CHIFFRE QUI DECIDE assainir vs regenerer\n{'#'*68}")
        show(cx, "parterres_ko | ko_sous_troncon_ko | ko_sous_troncon_ok",
             """SELECT
                  count(*) FILTER (WHERE NOT ST_IsValid(p.geom)),
                  count(*) FILTER (WHERE NOT ST_IsValid(p.geom) AND NOT ST_IsValid(t.geom)),
                  count(*) FILTER (WHERE NOT ST_IsValid(p.geom) AND     ST_IsValid(t.geom))
                FROM uti.parterres p
                JOIN uti.troncons_polygones t ON t.id_trc = p.id_trc;""")
        print("   ko_sous_troncon_OK domine -> defaut a la decoupe des parterres (14b suffit)")
        print("   ko_sous_troncon_KO domine -> defaut herite -> regenerer (02b/03b)")

        show(cx, "[C bis] Asymetrie pair/impair",
             """SELECT p.cote, count(*),
                       count(*) FILTER (WHERE NOT ST_IsValid(p.geom)) AS ko,
                       round(100.0*count(*) FILTER (WHERE NOT ST_IsValid(p.geom))/count(*),1) AS pct
                FROM uti.parterres p GROUP BY p.cote ORDER BY pct DESC;""")

        show(cx, "[D] INVARIANT d'aire troncons = parterres (via id_trc)",
             """SELECT
                  (SELECT round(sum(ST_Area(geom))::numeric,2) FROM uti.troncons_polygones) AS aire_troncons,
                  (SELECT round(sum(ST_Area(geom))::numeric,2) FROM uti.parterres)          AS aire_parterres;""")

        show(cx, "[E] Parterres slivers (< 5 m2) -- valides != pertinents",
             """SELECT count(*) FILTER (WHERE ST_Area(geom) < 5) AS slivers,
                       count(*) FILTER (WHERE ST_Area(geom) < 5 AND NOT ST_IsValid(geom)) AS slivers_ko
                FROM uti.parterres;""")

        show(cx, "[F1] troncons_adresses : lacunes attributaires connues",
             """SELECT
                  count(*)                                                        AS n_troncons,
                  count(*) FILTER (WHERE code_postal IS NULL)                      AS code_postal_null,
                  count(*) FILTER (WHERE taux_geocodage IS NULL)                   AS taux_null,
                  count(*) FILTER (WHERE nb_adresses = 0 AND (COALESCE(deb_gch,0)<>0
                        OR COALESCE(fin_gch,0)<>0 OR COALESCE(deb_drt,0)<>0
                        OR COALESCE(fin_drt,0)<>0))                                AS nb0_avec_plage
                FROM uti.troncons_adresses;""")

        show(cx, "[F2] Interferences ponctuelles non rattachees (id_trc NULL, hors chantier)",
             """SELECT count(*) FROM uti.interferences_troncon
                WHERE id_trc IS NULL AND categorie <> 'chantier';""")

        show(cx, "[F3] Arbres hors emprise MTM8 (anomalie xmax ~5 000 000)",
             """SELECT count(*) FROM uti.arbres
                WHERE ST_X(geom) NOT BETWEEN 260000 AND 320000
                   OR ST_Y(geom) NOT BETWEEN 5010000 AND 5075000;""")

        show(cx, "[F4] v_rues_limites_utg : une limite doit separer 2 UTG-A distinctes",
             """SELECT count(*) AS total,
                       count(*) FILTER (WHERE arr_gch = arr_drt) AS faux_limites,
                       count(*) FILTER (WHERE arr_gch IS NULL OR arr_drt IS NULL) AS cote_indetermine
                FROM uti.v_rues_limites_utg;""")

        # journal 14b si deja passe
        try:
            show(cx, "[LOG] Resultat de 14b (s'il a deja tourne)",
                 "SELECT couche, n_invalides_av, n_corrigees, n_invalides_ap, n_vides_ap FROM uti.log_correction_14b ORDER BY horodatage;")
        except Exception:
            pass


if __name__ == "__main__":
    main()
