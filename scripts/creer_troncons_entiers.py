#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
creer_troncons_entiers.py  (v5)
===============================
Livrable A — CARTHAB / UTI Montreal (Treevans)

Construit la couche de lecture ``uti.troncons_entiers`` : UN enregistrement par
RUE NOMMEE et spatialement connexe, a partir de la source LINEAIRE des
troncons de la Ville. Les segments-sources partageant le meme nom_rue sont
fusionnes (ST_Collect + ST_LineMerge), mais UNIQUEMENT au sein de chaque
groupe spatialement connecte (ST_ClusterDBSCAN, tolerance
TOLERANCE_JONCTION_M) : deux rues homonymes non connectees (ex. "3e Avenue"
a Verdun et "3e Avenue" a Lachine, ou une rue-limite avec une ville liee du
meme nom) restent deux entites distinctes plutot que d'etre fusionnees a tort.

Objectif : lecture claire du reseau — une rue = une entite continue sur toute
sa longueur, plutot qu'une entite par bloc (id_trc) coupee a chaque
intersection — sans la fragmentation induite par le traitement polygonal
(parterres pair/impair, terre-pleins, debris, emprises).

Limite connue de GEOS : ST_LineMerge ne fusionne que les noeuds de degre 2
(chaine simple). A toute VRAIE intersection avec une rue perpendiculaire
(noeud de degre >= 3), la geometrie reste coupee en plusieurs parties — c'est
un MultiLineString topologiquement correct, pas un bug (voir colonne
coupee_par_intersections). Le gain du regroupement par nom_rue : UNE SEULE
entite/ligne d'attributs par rue (au lieu d'une par bloc), donc plus de
"coupures" visibles en tant que features QGIS distinctes une fois stylees
par une couleur unique.

Historique
----------
v2 : chargement du .env du projet (le mot de passe absent faisait basculer libpq
     sur GSSAPI -> erreur trompeuse "no password supplied").
v3 : le .env du projet utilise les cles DB_HOST / DB_PORT / DB_NAME / DB_USER /
     DB_PASS. Alias DB_PASS ajoute (v2 ne connaissait que DB_PASSWORD).
     Typage explicite des identifiants pour faire taire les avertissements
     Pylance sur quote_plus (aucun impact a l'execution).
v4 : regroupement par nom_rue au lieu de id_trc — v3 fusionnait seulement les
     segments-sources PARTAGEANT LE MEME id_trc, or chaque id_trc etait deja
     un segment unique dans la source (0 fusion reelle) : le resultat restait
     coupe a chaque intersection, comme le reseau source. v4 fusionne tous les
     id_trc d'une meme rue -> une entite continue par rue nommee.
v5 : v4 fusionnait TOUS les segments partageant un nom_rue, sans egard a la
     connexite spatiale -> une rue avait jusqu'a 1985 "blocs" (collision de
     noms entre rues homonymes non connectees, frequent avec les avenues
     numerotees repetees dans plusieurs quartiers). v5 ajoute un clustering
     spatial (ST_ClusterDBSCAN) au sein de chaque nom_rue : seuls les
     segments reellement connectes (ou proches de TOLERANCE_JONCTION_M) sont
     fusionnes ensemble. Quand un nom se repete sur plusieurs groupes
     disjoints, chaque groupe devient une ligne distincte, numerotee via
     groupe_homonyme / nb_groupes_homonymes.

Convention CARTHAB : aucun script numerote modifie ; non destructif ; SQL via
SQLAlchemy uniquement (jamais psql, aucune meta-commande).

Execution :
    conda activate uti-montreal
    cd D:\\uti_montreal_pipeline_updated\\scripts
    python creer_troncons_entiers.py
"""

import os
import re
import sys
from pathlib import Path
from typing import Optional
from urllib.parse import quote_plus

from sqlalchemy import create_engine, text

SRID = 2950

# Tolerance (m) du clustering spatial ST_ClusterDBSCAN : deux segments-sources
# de meme nom_rue sont consideres comme la MEME rue s'ils sont connectes ou
# separes de moins de cette distance (tolere un petit ecart de digitalisation
# aux intersections). Au-dela, ce sont deux rues homonymes distinctes.
TOLERANCE_JONCTION_M = 0.5


# ==========================================================================
# 1. Connexion — .env du projet, puis variables d'environnement
# ==========================================================================
def charger_env() -> Optional[Path]:
    """Remonte l'arborescence depuis ce script et charge le premier .env trouve.
    N'ecrase pas les variables deja definies dans l'environnement."""
    ici = Path(__file__).resolve()
    candidats = [p / ".env" for p in [ici.parent, *ici.parents]]
    candidats.append(Path.cwd() / ".env")

    for env in candidats:
        if not env.is_file():
            continue
        for ligne in env.read_text(encoding="utf-8-sig").splitlines():
            ligne = ligne.strip()
            if not ligne or ligne.startswith("#") or "=" not in ligne:
                continue
            cle, val = ligne.split("=", 1)
            # Retire un commentaire de fin de ligne eventuel
            val = val.split(" #", 1)[0]
            os.environ.setdefault(cle.strip(),
                                  val.strip().strip('"').strip("'"))
        return env
    return None


def premiere_valeur(*cles: str, defaut: str = "") -> str:
    """Retourne toujours une str (jamais None) — evite les faux positifs Pylance."""
    for c in cles:
        v = os.environ.get(c)
        if v not in (None, ""):
            return str(v)
    return defaut


def get_engine():
    fichier_env = charger_env()

    # Cas 1 : une URL complete est fournie
    url_directe = premiere_valeur("DATABASE_URL", "PG_DSN", "POSTGRES_URL")
    if url_directe:
        url = re.sub(r"^postgres(ql)?://", "postgresql+psycopg2://", url_directe)
        return create_engine(url, future=True), fichier_env, "DATABASE_URL"

    # Cas 2 : reconstruction depuis les composantes.
    # Ordre des alias : convention du projet (DB_*) d'abord, puis libpq (PG*).
    host = premiere_valeur("DB_HOST", "PGHOST", "POSTGRES_HOST",
                           defaut="localhost")
    port = premiere_valeur("DB_PORT", "PGPORT", "POSTGRES_PORT",
                           defaut="5432")
    base = premiere_valeur("DB_NAME", "PGDATABASE", "POSTGRES_DB", "PGDB",
                           defaut="uti_montreal")
    user = premiere_valeur("DB_USER", "PGUSER", "POSTGRES_USER",
                           defaut="ndoune")
    pwd = premiere_valeur("DB_PASS", "DB_PASSWORD", "PGPASSWORD",
                          "POSTGRES_PASSWORD", "PGPASS")

    if not pwd:
        print("[FAIL] Aucun mot de passe PostgreSQL trouve.")
        print(f"       Fichier .env detecte : {fichier_env or 'AUCUN'}")
        print("       Cles acceptees : DB_PASS | DB_PASSWORD | PGPASSWORD")
        print("                        (ou DATABASE_URL complete)")
        print("")
        print("       Sans mot de passe, libpq bascule sur GSSAPI -> erreur")
        print("       'no password supplied'.")
        print("")
        print("       Depannage rapide, session PowerShell courante :")
        print('           $env:DB_PASS = "votre_mot_de_passe"')
        sys.exit(1)

    url = (f"postgresql+psycopg2://{quote_plus(str(user))}:{quote_plus(str(pwd))}"
           f"@{host}:{port}/{base}")
    return create_engine(url, future=True), fichier_env, f"{user}@{host}:{port}/{base}"


# ==========================================================================
# 2. Resolution de schema (ordre = priorite)
# ==========================================================================
SOURCES_LINEAIRES = [
    ("raw", "troncons_officiels"),
    ("raw", "troncon_mtl"),
    ("raw", "troncons"),
    ("raw", "reseau_routier"),
    ("raw", "reseau_routier_mtl"),
    ("uti", "troncons_axes"),
]

CANDIDATS_ID_TRC = ["id_trc", "id_troncon", "idtrc", "num_troncon", "no_troncon"]
CANDIDATS_NOM_RUE = ["nom_rue", "nom_voie", "toponyme", "topony", "nom_topog",
                     "libelle", "nom", "rue"]
CANDIDATS_TYPE = ["type_voie", "classe", "cls_rte", "typ_rte", "clas_rte",
                  "categorie", "type"]

TABLE_ARR = ("uti", "troncons_polygones")
COL_ARR_GAUCHE = "arr_gch"
COL_ARR_DROITE = "arr_drt"

TABLE_CIBLE = ("uti", "troncons_entiers")


def table_existe(conn, schema, table) -> bool:
    q = text("""SELECT 1 FROM information_schema.tables
                WHERE table_schema=:s AND table_name=:t LIMIT 1""")
    return conn.execute(q, {"s": schema, "t": table}).first() is not None


def colonnes(conn, schema, table) -> set:
    q = text("""SELECT lower(column_name) AS c FROM information_schema.columns
                WHERE table_schema=:s AND table_name=:t""")
    return {r.c for r in conn.execute(q, {"s": schema, "t": table})}


def col_geom(conn, schema, table):
    q = text("""SELECT column_name FROM information_schema.columns
                WHERE table_schema=:s AND table_name=:t AND udt_name='geometry'
                LIMIT 1""")
    r = conn.execute(q, {"s": schema, "t": table}).first()
    return r[0] if r else None


def premier_present(candidats, dispo):
    for c in candidats:
        if c in dispo:
            return c
    return None


def lister_tables_lignes(conn):
    q = text("""SELECT f_table_schema, f_table_name, type FROM geometry_columns
                WHERE type ILIKE '%LINESTRING%' ORDER BY 1, 2""")
    return list(conn.execute(q))


# ==========================================================================
# 3. Construction
# ==========================================================================
def main():
    eng, fichier_env, cible_cnx = get_engine()
    print(f"  .env .............. {fichier_env or 'aucun (variables env. seules)'}")
    print(f"  Connexion ......... {cible_cnx}")

    try:
        with eng.connect() as c:
            c.execute(text("SELECT 1"))
    except Exception as e:
        print("")
        print("[FAIL] Connexion a PostGIS impossible.")
        print(f"       {type(e).__name__}: {str(e).splitlines()[0]}")
        print("       Verifier que le conteneur tourne : docker compose up -d")
        print("       Verifier aussi que DB_PASS correspond bien au mot de passe")
        print("       du conteneur (et n'est pas reste a 'changer_moi').")
        sys.exit(1)

    with eng.connect() as r:
        src = None
        for sch, tab in SOURCES_LINEAIRES:
            if table_existe(r, sch, tab):
                g = col_geom(r, sch, tab)
                if g:
                    src = (sch, tab, g)
                    break

        if not src:
            print("")
            print("[FAIL] Aucune source lineaire de troncons trouvee. Teste :")
            for s, t in SOURCES_LINEAIRES:
                print(f"        - {s}.{t}")
            print("       Tables geometry de type ligne disponibles :")
            for row in lister_tables_lignes(r):
                print(f"        - {row[0]}.{row[1]} ({row[2]})")
            print("       -> Ajouter la bonne (schema, table) en tete de "
                  "SOURCES_LINEAIRES puis relancer.")
            sys.exit(1)

        sch, tab, gcol = src
        dispo = colonnes(r, sch, tab)
        id_trc = premier_present(CANDIDATS_ID_TRC, dispo)
        nom = premier_present(CANDIDATS_NOM_RUE, dispo)
        typv = premier_present(CANDIDATS_TYPE, dispo)

        if not id_trc:
            print("")
            print(f"[FAIL] Aucune colonne id_trc reconnue dans {sch}.{tab}.")
            print("       Colonnes presentes :", sorted(dispo))
            sys.exit(1)

        arr_ok = table_existe(r, *TABLE_ARR)
        arr_cols = colonnes(r, *TABLE_ARR) if arr_ok else set()
        id_trc_arr = premier_present(CANDIDATS_ID_TRC, arr_cols) if arr_ok else None
        arr_dispo = bool(arr_ok and id_trc_arr
                         and COL_ARR_GAUCHE in arr_cols
                         and COL_ARR_DROITE in arr_cols)

    srid_src = None
    try:
        with eng.connect() as c:
            srid_src = c.execute(text("SELECT Find_SRID(:s,:t,:g)"),
                                 {"s": sch, "t": tab, "g": gcol}).scalar()
    except Exception:
        srid_src = None
    if not srid_src:
        with eng.connect() as c:
            srid_src = c.execute(text(
                f'SELECT ST_SRID("{gcol}") FROM {sch}.{tab} '
                f'WHERE "{gcol}" IS NOT NULL LIMIT 1')).scalar() or 0

    if srid_src == SRID:
        geom_norm = f'"{gcol}"'
    elif srid_src == 0:
        geom_norm = f'ST_SetSRID("{gcol}", {SRID})'
    else:
        geom_norm = f'ST_Transform("{gcol}", {SRID})'

    print("")
    print("-------- Resolution --------")
    print(f"  Source lineaire ... {sch}.{tab}  (geom={gcol}, SRID={srid_src})")
    print(f"  id_trc ............ {id_trc}")
    print(f"  nom_rue ........... {nom or 'NON TROUVE -> NULL'}")
    print(f"  type_voie ......... {typv or 'NON TROUVE -> NULL'}")
    print(f"  arrondissement .... {'oui' if arr_dispo else 'non enrichi -> NULL'}")
    print("----------------------------")

    nom_expr = f'"{nom}"' if nom else 'NULL::text'
    typv_expr = f'"{typv}"' if typv else 'NULL::text'
    cible = f"{TABLE_CIBLE[0]}.{TABLE_CIBLE[1]}"

    # Arrondissement : calcule par id_trc (mode gauche/droite, comme avant),
    # puis agrege par rue -> liste des arrondissements distincts traverses
    # (ex. "Villeray | Ahuntsic" pour une rue-limite entre deux UTG).
    if arr_dispo:
        cte_arr = f'''
    arr AS (
        SELECT "{id_trc_arr}"::text AS id_trc,
               mode() WITHIN GROUP (ORDER BY "{COL_ARR_GAUCHE}") AS arr_g,
               mode() WITHIN GROUP (ORDER BY "{COL_ARR_DROITE}") AS arr_d
        FROM {TABLE_ARR[0]}.{TABLE_ARR[1]}
        GROUP BY "{id_trc_arr}"::text
    ),'''
        join_arr = "LEFT JOIN arr a ON a.id_trc = s.id_trc"
        arr_troncon_expr = '''CASE
               WHEN a.arr_g IS NOT DISTINCT FROM a.arr_d THEN a.arr_g
               WHEN a.arr_g IS NULL THEN a.arr_d
               WHEN a.arr_d IS NULL THEN a.arr_g
               ELSE a.arr_g || ' | ' || a.arr_d
           END'''
        arr_agg = "string_agg(DISTINCT arr_troncon, ' | ' ORDER BY arr_troncon) AS arrondissement,"
    else:
        cte_arr = ""
        join_arr = ""
        arr_troncon_expr = "NULL::text"
        arr_agg = "NULL::text AS arrondissement,"

    sql_build = f'''
    DROP TABLE IF EXISTS {cible} CASCADE;

    CREATE TABLE {cible} AS
    WITH src AS (
        SELECT "{id_trc}"::text                    AS id_trc,
               NULLIF(btrim({nom_expr}::text), '')  AS nom_rue,
               NULLIF(btrim({typv_expr}::text), '') AS type_voie,
               ({geom_norm})                        AS geom
        FROM {sch}.{tab}
        WHERE "{id_trc}" IS NOT NULL
          AND {geom_norm} IS NOT NULL
          AND NOT ST_IsEmpty({geom_norm})
          AND GeometryType({geom_norm}) IN ('LINESTRING', 'MULTILINESTRING')
    ),{cte_arr}
    cle AS (
        SELECT s.*,
               COALESCE(s.nom_rue, 'SANS_NOM_' || s.id_trc) AS cle_rue,
               {arr_troncon_expr} AS arr_troncon,
               -- Cluster spatial au sein de chaque nom_rue (ou cle unique pour
               -- les segments sans nom) : separe les rues homonymes non
               -- connectees (ex. avenues numerotees repetees par quartier).
               ST_ClusterDBSCAN(s.geom, {TOLERANCE_JONCTION_M}, 1)
                   OVER (PARTITION BY COALESCE(s.nom_rue, 'SANS_NOM_' || s.id_trc)) AS grappe
        FROM src s
        {join_arr}
    ),
    grp AS (
        SELECT cle_rue, grappe,
               MAX(nom_rue)                              AS nom_rue,
               mode() WITHIN GROUP (ORDER BY type_voie)  AS type_voie,
               {arr_agg}
               COUNT(*)                                   AS nb_segments_source,
               COUNT(DISTINCT id_trc)                      AS nb_troncons,
               ST_LineMerge(ST_Collect(geom))               AS geom
        FROM cle
        GROUP BY cle_rue, grappe
    ),
    grp2 AS (
        SELECT g.*,
               CASE WHEN nom_rue IS NOT NULL
                    THEN COUNT(*) OVER (PARTITION BY nom_rue) END AS nb_groupes_homonymes,
               CASE WHEN nom_rue IS NOT NULL
                    THEN ROW_NUMBER() OVER (PARTITION BY nom_rue ORDER BY grappe) END AS groupe_homonyme
        FROM grp g
    )
    SELECT ROW_NUMBER() OVER (ORDER BY nom_rue NULLS LAST, cle_rue, grappe)::int
                                                        AS id_rue_entiere,
           nom_rue,
           CASE WHEN nb_groupes_homonymes > 1 THEN groupe_homonyme END       AS groupe_homonyme,
           CASE WHEN nb_groupes_homonymes > 1 THEN nb_groupes_homonymes END  AS nb_groupes_homonymes,
           arrondissement,
           type_voie,
           ROUND(ST_Length(geom)::numeric, 2)           AS longueur_m,
           nb_troncons,
           nb_segments_source,
           ST_NumGeometries(ST_Multi(geom)) > 1          AS coupee_par_intersections,
           ST_Multi(geom)::geometry(MultiLineString, {SRID}) AS geom
    FROM grp2;
    '''

    with eng.begin() as w:
        w.execute(text(sql_build))
        w.execute(text(f'ALTER TABLE {cible} ADD PRIMARY KEY (id_rue_entiere);'))
        w.execute(text(f'CREATE INDEX ON {cible} USING GIST (geom);'))
        w.execute(text(f'CREATE INDEX ON {cible} (nom_rue);'))

    with eng.connect() as r:
        n_total = r.execute(text(f'SELECT COUNT(*) FROM {cible}')).scalar()
        n_nonom = r.execute(text(
            f"SELECT COUNT(*) FROM {cible} WHERE nom_rue IS NULL")).scalar()
        n_multi_blocs = r.execute(text(
            f'SELECT COUNT(*) FROM {cible} WHERE nb_troncons > 1')).scalar()
        n_coupee = r.execute(text(
            f'SELECT COUNT(*) FROM {cible} WHERE coupee_par_intersections')).scalar()
        n_lim = r.execute(text(
            f"SELECT COUNT(*) FROM {cible} WHERE arrondissement LIKE '% | %'")).scalar()
        n_inv = r.execute(text(f'SELECT COUNT(*) FROM {cible} WHERE NOT ST_IsValid(geom)')).scalar()
        long_tot = r.execute(text(f'SELECT ROUND(SUM(longueur_m)::numeric,0) FROM {cible}')).scalar()
        max_troncons = r.execute(text(f'SELECT MAX(nb_troncons) FROM {cible}')).scalar()
        n_homonymes = r.execute(text(
            f'SELECT COUNT(*) FROM {cible} WHERE nb_groupes_homonymes IS NOT NULL')).scalar()
        n_noms_homonymes = r.execute(text(
            f'SELECT COUNT(DISTINCT nom_rue) FROM {cible} WHERE nb_groupes_homonymes IS NOT NULL')).scalar()

    print("")
    print(f"-------- {cible} --------")
    print(f"  Rues entieres (1 ligne/rue) .. {n_total:>8}")
    print(f"  Sans nom_rue (1 ligne/bloc) .. {n_nonom:>8}")
    print(f"  Composees de >1 bloc ......... {n_multi_blocs:>8}")
    print(f"  Encore coupees (intersections) {n_coupee:>8}  (limite GEOS ST_LineMerge, cf. en-tete)")
    print(f"  Rues-limites (arr X | Y) ..... {n_lim:>8}")
    print(f"  Homonymes separes (groupes) .. {n_homonymes:>8}  ({n_noms_homonymes} noms distincts, cf. groupe_homonyme)")
    print(f"  Geometries invalides ......... {n_inv:>8}")
    print(f"  Max blocs sur une seule rue .. {max_troncons:>8}")
    print(f"  Longueur totale (m) .......... {long_tot:>8}")
    print("-----------------------------------------")

    with eng.connect().execution_options(isolation_level="AUTOCOMMIT") as c:
        c.execute(text(f'ANALYZE {cible};'))


if __name__ == "__main__":
    main()