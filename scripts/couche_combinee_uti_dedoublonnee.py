#!/usr/bin/env python
# -*- coding: utf-8 -*-
# =============================================================================
#  couche_combinee_uti.py
#  ---------------------------------------------------------------------------
#  Consolidation de TOUTES les couches UTI (Livrable A) dans UNE seule couche.
#  (Voir en-tete complet dans la version projet.)
# =============================================================================

import os
import sys
import shutil
import subprocess

from sqlalchemy import create_engine, text

# -----------------------------------------------------------------------------
# 1. CONFIGURATION
# -----------------------------------------------------------------------------

MODE = "maitresse"          # "maitresse" | "empilee"
INCLURE_TERRE_PLEINS = True # les terre-pleins comptent comme emplacements
SRID = 2950                 # NAD83 MTM8

SCHEMA_SRC = "uti"          # schema par defaut des couches deja transformees
SCHEMA_OUT = "uti"          # schema de la table de sortie

# Distance max (m) parterre <-> facade d'un batiment pour le comptage des
# batiments RIVERAINS (proximite, ST_DWithin ; pas intersection).
SEUIL_BATI_M = 20

SCHEMAS_SRC = ["uti", "raw"]

TABLE_OUT_MAITRESSE_BRUTE = "couche_maitresse_brute"
TABLE_OUT_MAITRESSE = "couche_maitresse"
TABLE_OUT_CONTROLE_UNIQUE = "couche_maitresse_controle_unique"
TABLE_OUT_EMPILEE   = "couche_empilee"

TABLE_QA_TP_COUVERTURE = "qa_terre_pleins_couverture"
TABLE_QA_TP_A_INSPECTER = "qa_terre_pleins_a_inspecter"
TABLE_QA_TP_DOUBLONS = "qa_terre_pleins_doublons"

EXPORT_GPKG = True
# Repli si config.yaml (cle sorties.uti_routieres_gpkg) est absent ou illisible.
# Ce script produit desormais le livrable A final : meme fichier que
# 03_export_gpkg.py visait auparavant (voir _resoudre_gpkg_path ci-dessous).
GPKG_PATH_DEFAUT = r"data/processed/UTI_Routieres.gpkg"

# Surface totale attendue des parterres (vraie partition, apres 02b/02c/02d).
# Sert de simple controle de coherence, PAS d'assertion bloquante.
SURFACE_PARTERRES_ATTENDUE = 100_669_683  # m2

SEUIL_QUASI_IDENTIQUE = 0.95

COLONNES_SOURCE_EMPLACEMENT = [
    "id_treevans", "demi_id", "arr_appartenance", "utg_id",
    "statut_voie", "type_voie", "usage_voie", "statut_public_prive",
    "perimetre_m", "rang_surface", "flag_multi_parterre",
    "presence_trottoir", "presence_saillie", "presence_piste_cyclable",
]

COLONNES_LIVRABLE = [
    "id_emplacement", "type_emplacement", "cote", "id_troncon",
    "id_treevans", "nom_rue",
    "arr_appartenance", "utg_id", "statut_voie", "type_voie", "usage_voie",
    "adresses", "nb_adresses", "plage_civique",
    "lots", "nb_lots",
    "presence_trottoir", "presence_saillie", "presence_piste_cyclable",
    "a_ruelle_verte",
    "nb_arbres", "nb_chantiers", "nb_batiments", "composantes_voirie", "materiau",
    "zonage_dominant",
    "surface_m2", "perimetre_m",
    "statut_dedoublonnage",
    "geom",
]
TABLE_OUT_LIVRABLE = "couche_maitresse_livrable"

TABLES_CANDIDATES = {
    "parterres":              ["parterres", "uti_parterres"],
    "terre_pleins":           ["terre_pleins", "uti_terre_pleins"],
    "troncons":               ["troncons_polygones", "troncons", "uti_troncons"],
    "adresses":               ["troncons_adresses", "adresses_troncon", "uti_adresses_troncon"],
    "lots":                   ["troncons_lots", "uti_troncons_lots"],
    "arbres":                 ["arbres", "uti_arbres"],
    "batiments":              ["batiments", "batiment", "bati", "uti_batiments"],
    "pistes_cyclables":       ["pistes_cyclables", "uti_pistes_cyclables"],
    "reseau_cyclable":        ["ref_reseau_cyclable", "reseau_cyclable"],
    "ruelles_vertes":         ["ref_ruelles_vertes", "ruelles_vertes"],
    "chantiers":              ["chantier_routier", "interferences_chantiers", "uti_interferences_chantiers"],
    "interf_ponctuelles":     ["interferences_ponctuelles", "uti_interferences_ponctuelles"],
    "composantes_voirie":     ["composantes_voirie", "uti_composantes_voirie"],
    "zonage":                 ["ref_zonage", "zonage", "zonage_mtl"],
    "voirie_materiau":        ["voirie_active", "composantes_voirie",
                               "ref_voirie_active"],
    "rues_limites_utg":       ["v_rues_limites_utg", "rues_limites_utg", "uti_rues_limites_utg"],
}

COL_COTE    = ["cote", "cote_rue", "parite"]
COL_ID_TRC  = ["id_trc", "id_troncon", "no_troncon", "id_troncon_poly",
               "cle_troncon", "id", "gid", "objectid"]
COL_FK_TRC  = ["id_trc", "id_troncon", "troncon_id", "no_troncon",
               "id_troncon_poly", "cle_troncon", "gid_troncon"]
COL_ID_LOT  = ["no_lot", "numero_lot", "id_lot", "lot", "gid", "id"]
COL_RUE     = ["nom_rue", "rue", "nom_voie", "toponyme", "nom"]
COL_ZONAGE  = ["code_zonage", "zonage", "affectation", "affectatio", "usage", "categorie", "grande_affectation"]
COL_MATERIAU = ["materiau", "material", "matiere", "revetement", "type_revetement",
                "mat_revet", "revetement_type", "type_surface", "surface_type"]
COL_TYPE_CV = ["type", "type_composante", "categorie", "classe"]


# -----------------------------------------------------------------------------
# 2. CONNEXION
# -----------------------------------------------------------------------------

_RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _charger_dotenv():
    try:
        from dotenv import load_dotenv
        for chemin in (os.path.join(_RACINE, ".env"), ".env"):
            if os.path.exists(chemin):
                load_dotenv(chemin)
        return
    except Exception:
        pass
    for chemin in (os.path.join(_RACINE, ".env"), ".env"):
        if os.path.exists(chemin):
            with open(chemin, encoding="utf-8") as f:
                for ligne in f:
                    ligne = ligne.strip()
                    if ligne and not ligne.startswith("#") and "=" in ligne:
                        k, v = ligne.split("=", 1)
                        os.environ.setdefault(k.strip(),
                                              v.strip().strip('"').strip("'"))


def _section_config_yaml():
    for chemin in (os.path.join(_RACINE, "config.yaml"), "config.yaml"):
        if not os.path.exists(chemin):
            continue
        try:
            import yaml
            with open(chemin, encoding="utf-8") as f:
                cfg = yaml.safe_load(f) or {}
        except Exception:
            return {}
        for cle in ("database", "db", "postgres", "postgis", "connection"):
            if isinstance(cfg.get(cle), dict):
                return cfg[cle]
    return {}


def _resoudre_gpkg_path():
    """Chemin du GeoPackage livrable : cle sorties.uti_routieres_gpkg de
    config.yaml (meme convention que 03_export_gpkg.py), repli sur
    GPKG_PATH_DEFAUT si la cle ou le fichier est absent."""
    for chemin in (os.path.join(_RACINE, "config.yaml"), "config.yaml"):
        if not os.path.exists(chemin):
            continue
        try:
            import yaml
            with open(chemin, encoding="utf-8") as f:
                cfg = yaml.safe_load(f) or {}
            p = (cfg.get("sorties") or {}).get("uti_routieres_gpkg")
            if p:
                return p
        except Exception:
            pass
    return GPKG_PATH_DEFAUT


def _param(cands_env, cfg, cles_cfg, defaut=None):
    for k in cands_env:
        if os.environ.get(k):
            return os.environ[k]
    for k in cles_cfg:
        if cfg.get(k) not in (None, ""):
            return str(cfg[k])
    return defaut


def _params_connexion():
    _charger_dotenv()
    for k in ("DATABASE_URL", "SQLALCHEMY_DATABASE_URI", "DB_URL"):
        if os.environ.get(k):
            return {"url": os.environ[k]}
    cfg = _section_config_yaml()
    return dict(
        host=_param(["PGHOST", "POSTGRES_HOST", "DB_HOST"], cfg, ["host"], "localhost"),
        port=_param(["PGPORT", "POSTGRES_PORT", "DB_PORT"], cfg, ["port"], "5432"),
        db=_param(["PGDATABASE", "POSTGRES_DB", "DB_NAME", "DB_DATABASE"], cfg,
                  ["dbname", "database", "name", "db"], "uti_montreal"),
        user=_param(["PGUSER", "POSTGRES_USER", "DB_USER"], cfg, ["user", "username"], "ndoune"),
        pwd=_param(["PGPASSWORD", "POSTGRES_PASSWORD", "DB_PASSWORD", "DB_PASS"],
                   cfg, ["password", "pass", "pwd"], None),
    )


def creer_engine():
    from sqlalchemy import URL
    p = _params_connexion()
    cargs = {"gssencmode": "disable"}

    url_directe = p.get("url")
    if url_directe:
        print("  [connexion] via URL fournie")
        return create_engine(url_directe, future=True, connect_args=cargs)

    pwd = p.get("pwd")
    if not pwd:
        sys.exit(
            "\nERREUR de connexion : aucun mot de passe trouve.\n"
            "  Le script lit, dans l'ordre : DATABASE_URL, puis les variables\n"
            "  d'environnement / .env (PGPASSWORD | POSTGRES_PASSWORD | DB_PASSWORD),\n"
            "  puis une section 'database:' de config.yaml.\n\n"
            "    PowerShell (session courante) :  $env:PGPASSWORD = 'ton_mdp'\n"
            "    .env du projet                :  PGPASSWORD=ton_mdp\n"
            "    URL complete                  :  DATABASE_URL="
            "postgresql+psycopg2://ndoune:ton_mdp@localhost:5432/uti_montreal\n"
        )

    host = p.get("host") or "localhost"
    port = int(p.get("port") or 5432)
    db   = p.get("db") or "uti_montreal"
    user = p.get("user") or "ndoune"
    url = URL.create("postgresql+psycopg2", username=user, password=pwd,
                     host=host, port=port, database=db)
    print(f"  [connexion] {user}@{host}:{port}/{db}  (mdp: ***)")
    return create_engine(url, future=True, connect_args=cargs)


# -----------------------------------------------------------------------------
# 3. INSPECTION DU SCHEMA
# -----------------------------------------------------------------------------

def tables_du_schema(conn, schema):
    q = text("""
        SELECT table_name FROM information_schema.tables WHERE table_schema = :s
        UNION
        SELECT table_name FROM information_schema.views WHERE table_schema = :s
    """)
    return {r[0] for r in conn.execute(q, {"s": schema})}


def colonnes(conn, schema, table):
    q = text("""
        SELECT column_name, udt_name
        FROM information_schema.columns
        WHERE table_schema = :s AND table_name = :t
        ORDER BY ordinal_position
    """)
    return [(r[0], r[1]) for r in conn.execute(q, {"s": schema, "t": table})]


def info_geom(conn, schema, table):
    q = text("""
        SELECT f_geometry_column, srid
        FROM geometry_columns
        WHERE f_table_schema = :s AND f_table_name = :t
        ORDER BY (f_geometry_column = 'geom') DESC, f_geometry_column
        LIMIT 1
    """)
    r = conn.execute(q, {"s": schema, "t": table}).fetchone()
    if r:
        return r[0], r[1]
    for col, udt in colonnes(conn, schema, table):
        if udt == "geometry":
            try:
                srid = conn.execute(
                    text(f'SELECT ST_SRID("{col}") FROM "{schema}"."{table}" '
                         f'WHERE "{col}" IS NOT NULL LIMIT 1')
                ).scalar()
            except Exception:
                srid = None
            return col, srid
    return None, None


def geom_src_srid(alias, gcol, srid_src):
    if srid_src and srid_src not in (0, SRID):
        return f'ST_Transform({alias}."{gcol}", {SRID})'
    return f'{alias}."{gcol}"'


def _table_ref_valide(conn, nom_tmp, sch, table, attr_col, geom_col, srid_src):
    if srid_src and srid_src not in (0, SRID):
        gexpr = f'ST_Transform("{geom_col}", {SRID})'
    else:
        gexpr = f'"{geom_col}"'
    conn.execute(text(f"DROP TABLE IF EXISTS {nom_tmp}"))
    conn.execute(text(f"""
        CREATE TEMP TABLE {nom_tmp} AS
        SELECT "{attr_col}"::text AS attr,
               CASE WHEN ST_IsValid({gexpr}) THEN {gexpr}
                    ELSE ST_CollectionExtract(ST_MakeValid({gexpr}), 3)
               END AS geom
        FROM "{sch}"."{table}"
        WHERE "{attr_col}" IS NOT NULL
    """))
    conn.execute(text(f"CREATE INDEX ON {nom_tmp} USING GIST (geom)"))
    conn.execute(text(f"ANALYZE {nom_tmp}"))


def resoudre(candidats, disponibles):
    bas = {d.lower(): d for d in disponibles}
    for c in candidats:
        if c.lower() in bas:
            return bas[c.lower()]
    return None


def cle_commune(conn, schema, table_a, table_b):
    cols_a = colonnes(conn, schema, table_a)
    noms_b = {n.lower() for n, _ in colonnes(conn, schema, table_b)}
    bruit = {"geom", "geometry", "the_geom", "cote", "cote_rue", "parite",
             "gid", "fid", "objectid", "id", "surface", "surface_m2",
             "longueur", "geom_valide", "geom_source"}
    communs = [(n, u) for (n, u) in cols_a
               if n.lower() in noms_b and n.lower() not in bruit and u != "geometry"]
    if not communs:
        return None

    def score(nom):
        nl, s = nom.lower(), 0
        if "trc" in nl or "tronc" in nl:      s += 3
        if nl.startswith("id") or nl.endswith("id"): s += 2
        if "cle" in nl or "code" in nl:       s += 1
        return s

    communs.sort(key=lambda x: score(x[0]), reverse=True)
    return communs[0][0]


SCHEMA_PAR_CLE = {}


def schema_de(cle):
    return SCHEMA_PAR_CLE.get(cle, SCHEMA_SRC)


def resoudre_tables(conn):
    SCHEMA_PAR_CLE.clear()
    dispo = {sch: tables_du_schema(conn, sch) for sch in SCHEMAS_SRC}
    resolues = {}
    for cle, cands in TABLES_CANDIDATES.items():
        trouve = None
        for sch in SCHEMAS_SRC:
            t = resoudre(cands, dispo[sch])
            if t:
                trouve = t
                SCHEMA_PAR_CLE[cle] = sch
                break
        resolues[cle] = trouve
        etat = f"{SCHEMA_PAR_CLE[cle]}.{trouve}" if trouve else "-- ABSENTE --"
        print(f"    [{cle:20s}] -> {etat}")
    return resolues


# -----------------------------------------------------------------------------
# 4. MODE MAITRESSE
# -----------------------------------------------------------------------------

def construire_maitresse(conn, T):
    out = f'"{SCHEMA_OUT}"."{TABLE_OUT_MAITRESSE_BRUTE}"'

    if not T["parterres"]:
        sys.exit("ERREUR : couche 'parterres' introuvable ; impossible de construire l'epine.")

    g_par, _ = info_geom(conn, SCHEMA_SRC, T["parterres"])
    cols_par = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["parterres"])]
    col_cote = resoudre(COL_COTE, cols_par)
    key_par  = resoudre(COL_ID_TRC, cols_par)

    print(f"  · epine       : {T['parterres']} (geom={g_par}, cote={col_cote or 'n/d'}, "
          f"id_troncon={key_par or 'n/d'})")

    sel_cote_par = f'p."{col_cote}"::text' if col_cote else "NULL::text"
    sel_key_par  = f'p."{key_par}"::text'  if key_par  else "NULL::text"

    udt_par = {n.lower(): u for n, u in colonnes(conn, SCHEMA_SRC, T["parterres"])}
    natifs = [(c, udt_par[c.lower()]) for c in COLONNES_SOURCE_EMPLACEMENT
              if c.lower() in udt_par]
    if natifs:
        print(f"  · attributs natifs propages : {', '.join(c for c, _ in natifs)}")
    sel_natifs_par = "".join(f',\n            p."{c}" AS "{c}"' for c, _ in natifs)
    sel_natifs_out = "".join(f',\n            e."{c}"' for c, _ in natifs)

    parts = [f"""
        SELECT
            'parterre'::text                       AS type_emplacement,
            {sel_cote_par}                         AS cote,
            {sel_key_par}                          AS id_troncon{sel_natifs_par},
            ST_Multi(p."{g_par}")::geometry(MultiPolygon,{SRID}) AS geom
        FROM "{SCHEMA_SRC}"."{T['parterres']}" p
        WHERE p."{g_par}" IS NOT NULL
    """]

    if INCLURE_TERRE_PLEINS and T["terre_pleins"]:
        g_tp, _ = info_geom(conn, SCHEMA_SRC, T["terre_pleins"])
        cols_tp = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["terre_pleins"])]
        key_tp  = resoudre(COL_ID_TRC, cols_tp)
        if g_tp:
            sel_key_tp = f'tp."{key_tp}"::text' if key_tp else "NULL::text"
            cols_tp_low = {c.lower() for c in cols_tp}
            sel_natifs_tp = "".join(
                (f',\n                    tp."{c}" AS "{c}"'
                 if c.lower() in cols_tp_low
                 else f',\n                    NULL::{u} AS "{c}"')
                for c, u in natifs)
            parts.append(f"""
                SELECT
                    'terre_plein'::text                    AS type_emplacement,
                    'central'::text                        AS cote,
                    {sel_key_tp}                           AS id_troncon{sel_natifs_tp},
                    ST_Multi(tp."{g_tp}")::geometry(MultiPolygon,{SRID}) AS geom
                FROM "{SCHEMA_SRC}"."{T['terre_pleins']}" tp
                WHERE tp."{g_tp}" IS NOT NULL
            """)
            print(f"  · terre-pleins: {T['terre_pleins']} inclus (id_troncon={key_tp or 'n/d'})")

    union_epine = "\nUNION ALL\n".join(parts)

    conn.execute(text(f"DROP TABLE IF EXISTS {out} CASCADE"))
    conn.execute(text(f"""
        CREATE TABLE {out} AS
        WITH epine AS (
            {union_epine}
        )
        SELECT
            row_number() OVER ()                    AS id_emplacement,
            e.type_emplacement,
            e.cote,
            e.id_troncon,
            ST_Area(e.geom)                         AS surface_m2{sel_natifs_out},
            e.geom
        FROM epine e
    """))
    conn.execute(text(f'ALTER TABLE {out} ADD PRIMARY KEY (id_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {out} USING GIST (geom)'))
    conn.execute(text(f'CREATE INDEX ON {out} (id_troncon)'))
    conn.execute(text(f'ANALYZE {out}'))

    n = conn.execute(text(f"SELECT count(*) FROM {out}")).scalar()
    n_lie = conn.execute(text(f"SELECT count(*) FROM {out} WHERE id_troncon IS NOT NULL")).scalar()
    print(f"  -> {n:,} emplacements ({n_lie:,} avec id_troncon)".replace(",", " "))

    id_trc = None
    if T["troncons"]:
        g_trc, _ = info_geom(conn, SCHEMA_SRC, T["troncons"])
        cols_trc = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["troncons"])]
        id_trc = resoudre(COL_ID_TRC, cols_trc)
        col_rue = resoudre(COL_RUE, cols_trc)

        print(f"    colonnes {T['troncons']:<20s}: {', '.join(cols_trc)}")
        if T["adresses"]:
            print(f"    colonnes {T['adresses']:<20s}: "
                  f"{', '.join(c for c, _ in colonnes(conn, SCHEMA_SRC, T['adresses']))}")

        if not id_trc and T["adresses"]:
            id_trc = cle_commune(conn, SCHEMA_SRC, T["troncons"], T["adresses"])
            if id_trc:
                print(f"    -> id tronçon deduit par colonne commune : '{id_trc}'")

        conn.execute(text(f"""
            ALTER TABLE {out}
                ADD COLUMN nom_rue            text,
                ADD COLUMN troncon_attributs  jsonb
        """))

        n_cle = conn.execute(text(f"SELECT count(*) FROM {out} WHERE id_troncon IS NOT NULL")).scalar()

        if id_trc and n_cle > 0:
            sel_rue = f't."{col_rue}"::text' if col_rue else "NULL::text"
            conn.execute(text(f"""
                UPDATE {out} o SET
                    nom_rue           = {sel_rue},
                    troncon_attributs = to_jsonb(t) - '{g_trc}'
                FROM "{SCHEMA_SRC}"."{T['troncons']}" t
                WHERE t."{id_trc}"::text = o.id_troncon
            """))
            mode_join = f"attributaire (id_troncon = {id_trc})"
        else:
            sel_id  = f't."{id_trc}"::text' if id_trc else "NULL::text"
            sel_rue = f't."{col_rue}"::text' if col_rue else "NULL::text"
            conn.execute(text(f"""
                UPDATE {out} o SET
                    id_troncon        = s.id_troncon,
                    nom_rue           = s.nom_rue,
                    troncon_attributs = s.attrs
                FROM (
                    SELECT o2.id_emplacement,
                           {sel_id}  AS id_troncon,
                           {sel_rue} AS nom_rue,
                           to_jsonb(t) - '{g_trc}' AS attrs
                    FROM {out} o2
                    JOIN "{SCHEMA_SRC}"."{T['troncons']}" t
                      ON ST_Contains(t."{g_trc}", ST_PointOnSurface(o2.geom))
                ) s
                WHERE o.id_emplacement = s.id_emplacement
            """))
            mode_join = "spatiale (repli, aucune cle attributaire)"

        rattaches = conn.execute(text(
            f"SELECT count(*) FROM {out} WHERE troncon_attributs IS NOT NULL")).scalar()
        print(f"  · tronçon     : {rattaches:,} emplacements rattaches "
              f"— {mode_join}, rue={col_rue or 'n/d'}".replace(",", " "))

    if T["adresses"] and id_trc:
        cols_adr = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["adresses"])]
        fk_adr   = resoudre(COL_FK_TRC, cols_adr)
        if not fk_adr and id_trc in cols_adr:
            fk_adr = id_trc
        col_txt = resoudre(["adresses_texte", "texte", "adresse",
                            "adresse_complete", "numero_civique"], cols_adr)
        col_nb  = resoudre(["nb_adresses"], cols_adr)
        col_cp  = resoudre(["code_postal", "cp"], cols_adr)
        has_gch = ("deb_gch" in cols_adr and "fin_gch" in cols_adr)
        has_drt = ("deb_drt" in cols_adr and "fin_drt" in cols_adr)

        adds, sets = [], []
        if col_txt:
            adds.append("adresses text")
            sets.append(f'adresses = a."{col_txt}"::text')
        if col_nb:
            adds.append("nb_adresses integer")
            sets.append(f'nb_adresses = NULLIF(a."{col_nb}"::text, \'\')::integer')
        if col_cp:
            adds.append("code_postal text")
            sets.append(f'code_postal = a."{col_cp}"::text')
        if has_gch or has_drt:
            adds.append("plage_civique text")
            cas = []
            if has_gch:
                cas.append("WHEN lower(o.cote) = 'impair' THEN "
                           "concat_ws('-', a.deb_gch::text, a.fin_gch::text)")
            if has_drt:
                cas.append("WHEN lower(o.cote) = 'pair' THEN "
                           "concat_ws('-', a.deb_drt::text, a.fin_drt::text)")
            sets.append("plage_civique = CASE " + " ".join(cas) + " ELSE NULL END")

        if fk_adr and sets:
            conn.execute(text("ALTER TABLE {o} ADD COLUMN {c}".format(
                o=out, c=", ADD COLUMN ".join(adds))))
            conn.execute(text(f"""
                UPDATE {out} o SET {', '.join(sets)}
                FROM "{SCHEMA_SRC}"."{T['adresses']}" a
                WHERE a."{fk_adr}"::text = o.id_troncon
            """))
            n_adr = conn.execute(text(
                f"SELECT count(*) FROM {out} "
                f"WHERE {'adresses' if col_txt else 'code_postal'} IS NOT NULL")).scalar()
            cp_pct = ""
            if col_cp:
                nn = conn.execute(text(
                    f"SELECT count(*) FROM {out} WHERE code_postal IS NOT NULL")).scalar()
                cp_pct = f", code_postal renseigne sur {nn:,}".replace(",", " ")
            print(f"  · adresses    : {n_adr:,} empl. renseignes "
                  f"(cle={fk_adr}, texte={col_txt}{cp_pct})".replace(",", " "))
        else:
            print("  · adresses    : cle/colonnes non resolues -> ignore")

    if T["lots"]:
        g_lot, _ = info_geom(conn, SCHEMA_SRC, T["lots"])
        cols_lot = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["lots"])]
        id_lot   = resoudre(COL_ID_LOT, cols_lot)
        if g_lot and id_lot:
            conn.execute(text(f"""
                ALTER TABLE {out}
                    ADD COLUMN lots    text,
                    ADD COLUMN nb_lots integer DEFAULT 0
            """))
            conn.execute(text(f"""
                UPDATE {out} o SET
                    lots    = s.liste,
                    nb_lots = s.n
                FROM (
                    SELECT o2.id_emplacement,
                           string_agg(DISTINCT l."{id_lot}"::text, ', ') AS liste,
                           count(DISTINCT l."{id_lot}"::text)            AS n
                    FROM {out} o2
                    JOIN "{SCHEMA_SRC}"."{T['lots']}" l
                      ON ST_Intersects(l."{g_lot}", o2.geom)
                    GROUP BY o2.id_emplacement
                ) s
                WHERE o.id_emplacement = s.id_emplacement
            """))
            print(f"  · lots        : jointure spatiale (id_lot={id_lot})")

    _compte_spatial(conn, out, T, "arbres",             "nb_arbres",             "count")
    _compte_spatial(conn, out, T, "interf_ponctuelles", "nb_interf_ponctuelles", "count")
    _compte_spatial(conn, out, T, "chantiers",          "nb_chantiers",          "count")
    _compte_spatial(conn, out, T, "pistes_cyclables",   "a_piste_cyclable",      "bool")
    _compte_spatial(conn, out, T, "reseau_cyclable",    "a_reseau_cyclable",     "bool")
    _compte_spatial(conn, out, T, "ruelles_vertes",     "a_ruelle_verte",        "bool")

    # -- Batiments RIVERAINS (proximite) -------------------------------------
    if T.get("batiments"):
        sch_bat = schema_de("batiments")
        g_bat, srid_bat = info_geom(conn, sch_bat, T["batiments"])
        if g_bat:
            if srid_bat in (0, None):
                print("  · batiments   : ATTENTION — SRID source inconnu, resultat a valider")
            gexpr_bat = (f'ST_Transform("{g_bat}", {SRID})'
                         if srid_bat and srid_bat not in (0, SRID) else f'"{g_bat}"')
            conn.execute(text("DROP TABLE IF EXISTS _ref_batiments"))
            conn.execute(text(f"""
                CREATE TEMP TABLE _ref_batiments AS
                SELECT CASE WHEN ST_IsValid({gexpr_bat}) THEN {gexpr_bat}
                            ELSE ST_CollectionExtract(ST_MakeValid({gexpr_bat}), 3)
                       END AS geom
                FROM "{sch_bat}"."{T['batiments']}"
                WHERE "{g_bat}" IS NOT NULL
            """))
            conn.execute(text("CREATE INDEX ON _ref_batiments USING GIST (geom)"))
            conn.execute(text("ANALYZE _ref_batiments"))
            conn.execute(text(f"ALTER TABLE {out} ADD COLUMN nb_batiments integer DEFAULT 0"))
            conn.execute(text(f"""
                UPDATE {out} o SET nb_batiments = s.n
                FROM (
                    SELECT o2.id_emplacement, count(*) AS n
                    FROM {out} o2
                    JOIN _ref_batiments b ON ST_DWithin(b.geom, o2.geom, {SEUIL_BATI_M})
                    GROUP BY o2.id_emplacement
                ) s
                WHERE o.id_emplacement = s.id_emplacement
            """))
            reproj = "" if (not srid_bat or srid_bat == SRID) else f", reprojete de {srid_bat}"
            print(f"  · batiments   : nb_batiments (proximite {SEUIL_BATI_M} m, {sch_bat}{reproj})")
        else:
            print("  · batiments   : couche sans geometrie -> ignore")
    else:
        print("  · batiments   : couche absente de PostGIS -> nb_batiments = 0")

    if T["composantes_voirie"]:
        sch_cv = schema_de("composantes_voirie")
        g_cv, srid_cv = info_geom(conn, sch_cv, T["composantes_voirie"])
        cols_cv = [c for c, _ in colonnes(conn, sch_cv, T["composantes_voirie"])]
        type_cv = resoudre(COL_TYPE_CV, cols_cv)
        if g_cv:
            gexpr_cv = geom_src_srid("cv", g_cv, srid_cv)
            conn.execute(text(f"ALTER TABLE {out} ADD COLUMN composantes_voirie text"))
            expr = (f"string_agg(DISTINCT cv.\"{type_cv}\"::text, ', ')"
                    if type_cv else "count(*)::text")
            conn.execute(text(f"""
                UPDATE {out} o SET composantes_voirie = s.v
                FROM (
                    SELECT o2.id_emplacement, {expr} AS v
                    FROM {out} o2
                    JOIN "{sch_cv}"."{T['composantes_voirie']}" cv
                      ON ST_Intersects({gexpr_cv}, o2.geom)
                    GROUP BY o2.id_emplacement
                ) s
                WHERE o.id_emplacement = s.id_emplacement
            """))
            print(f"  · comp. voirie: agregees (type={type_cv or 'nombre'}, {sch_cv})")

    # -- Zonage dominant (contenance du point representatif) ------------------
    if T["zonage"]:
        sch_zon = schema_de("zonage")
        g_zon, srid_zon = info_geom(conn, sch_zon, T["zonage"])
        cols_zon = [c for c, _ in colonnes(conn, sch_zon, T["zonage"])]
        col_zon  = resoudre(COL_ZONAGE, cols_zon)
        if g_zon and col_zon:
            if srid_zon in (0, None):
                print("  · zonage      : ATTENTION — SRID source inconnu, resultat a valider")
            _table_ref_valide(conn, "_ref_zonage", sch_zon, T["zonage"],
                              col_zon, g_zon, srid_zon)
            conn.execute(text(f"ALTER TABLE {out} ADD COLUMN zonage_dominant text"))
            conn.execute(text(f"""
                UPDATE {out} o SET zonage_dominant = z.attr
                FROM _ref_zonage z
                WHERE ST_Contains(z.geom, ST_PointOnSurface(o.geom))
            """))
            reproj = "" if (not srid_zon or srid_zon == SRID) else f", reprojete de {srid_zon}"
            print(f"  · zonage      : dominant (colonne={col_zon}, {sch_zon}{reproj})")
        elif g_zon and not col_zon:
            print(f"  · zonage      : colonne non resolue dans {sch_zon}.{T['zonage']}.")
            print(f"                  colonnes disponibles : {', '.join(cols_zon)}")
            print( "                  -> ajouter le nom reel a COL_ZONAGE.")

    if T["voirie_materiau"]:
        sch_voi = schema_de("voirie_materiau")
        g_voi, srid_voi = info_geom(conn, sch_voi, T["voirie_materiau"])
        cols_voi = [c for c, _ in colonnes(conn, sch_voi, T["voirie_materiau"])]
        col_mat  = resoudre(COL_MATERIAU, cols_voi)
        if g_voi and col_mat:
            if srid_voi in (0, None):
                print("  · materiau    : ATTENTION — SRID source inconnu, resultat a valider")
            _table_ref_valide(conn, "_ref_voirie", sch_voi, T["voirie_materiau"],
                              col_mat, g_voi, srid_voi)
            conn.execute(text(f"ALTER TABLE {out} ADD COLUMN materiau text"))
            conn.execute(text(f"""
                UPDATE {out} o SET materiau = v.attr
                FROM _ref_voirie v
                WHERE ST_Contains(v.geom, ST_PointOnSurface(o.geom))
            """))
            reproj = "" if (not srid_voi or srid_voi == SRID) else f", reprojete de {srid_voi}"
            print(f"  · materiau    : dominant depuis {sch_voi}.{T['voirie_materiau']} "
                  f"(colonne={col_mat}{reproj})")
        elif g_voi and not col_mat:
            print(f"  · materiau    : colonne non resolue dans {sch_voi}.{T['voirie_materiau']}.")
            print(f"                  colonnes disponibles : {', '.join(cols_voi)}")
            print( "                  -> ajouter le nom reel a COL_MATERIAU.")

    conn.execute(text(f"ANALYZE {out}"))
    return out


def _compte_spatial(conn, out, T, cle, col, mode):
    if not T.get(cle):
        return
    sch = schema_de(cle)
    g_src, srid_src = info_geom(conn, sch, T[cle])
    if not g_src:
        return
    if srid_src in (0, None):
        print(f"  · {cle:20s}: ATTENTION — SRID source inconnu ({sch}), resultat a valider")
    gexpr = geom_src_srid("s", g_src, srid_src)
    if mode == "bool":
        conn.execute(text(f"ALTER TABLE {out} ADD COLUMN {col} boolean DEFAULT false"))
        conn.execute(text(f"""
            UPDATE {out} o SET {col} = true
            WHERE EXISTS (
                SELECT 1 FROM "{sch}"."{T[cle]}" s
                WHERE ST_Intersects({gexpr}, o.geom)
            )
        """))
    else:
        conn.execute(text(f"ALTER TABLE {out} ADD COLUMN {col} integer DEFAULT 0"))
        conn.execute(text(f"""
            UPDATE {out} o SET {col} = s.n
            FROM (
                SELECT o2.id_emplacement, count(*) AS n
                FROM {out} o2
                JOIN "{sch}"."{T[cle]}" s ON ST_Intersects({gexpr}, o2.geom)
                GROUP BY o2.id_emplacement
            ) s
            WHERE o.id_emplacement = s.id_emplacement
        """))
    reproj = "" if (not srid_src or srid_src == SRID) else f", reprojete de {srid_src}"
    print(f"  · {cle:20s}: colonne {col} ({mode}, {sch}{reproj})")


# -----------------------------------------------------------------------------
# 5. MODE EMPILEE
# -----------------------------------------------------------------------------

def construire_empilee(conn, T):
    out = f'"{SCHEMA_OUT}"."{TABLE_OUT_EMPILEE}"'
    selects = []
    for cle, table in T.items():
        if not table:
            continue
        sch = schema_de(cle)
        g, srid = info_geom(conn, sch, table)
        if g:
            geom_expr = (f'ST_Transform("{g}", {SRID})' if srid and srid != SRID else f'"{g}"')
            geom_expr = f'ST_Multi({geom_expr})::geometry(Geometry,{SRID})'
            attrs = f'to_jsonb(t) - \'{g}\''
        else:
            geom_expr = f'NULL::geometry(Geometry,{SRID})'
            attrs = "to_jsonb(t)"
        selects.append(f"""
            SELECT '{cle}'::text AS couche_source,
                   '{table}'::text AS table_source,
                   {attrs} AS attributs,
                   {geom_expr} AS geom
            FROM "{sch}"."{table}" t
        """)

    if not selects:
        sys.exit("ERREUR : aucune couche source resolue.")

    union = "\nUNION ALL\n".join(selects)
    conn.execute(text(f"DROP TABLE IF EXISTS {out} CASCADE"))
    conn.execute(text(f"""
        CREATE TABLE {out} AS
        SELECT row_number() OVER () AS gid, u.*
        FROM ( {union} ) u
    """))
    conn.execute(text(f'ALTER TABLE {out} ADD PRIMARY KEY (gid)'))
    conn.execute(text(f'CREATE INDEX ON {out} USING GIST (geom)'))
    conn.execute(text(f'ANALYZE {out}'))

    print("  Repartition par couche source :")
    for r in conn.execute(text(f"""
            SELECT couche_source, count(*) n
            FROM {out} GROUP BY couche_source ORDER BY couche_source""")):
        print(f"    {r[0]:22s} {r[1]:>10,}".replace(",", " "))
    return out


# -----------------------------------------------------------------------------
# 6. VALIDATION & EXPORT
# -----------------------------------------------------------------------------

def valider_maitresse(conn, out):
    print("\n[VALIDATION]")
    surf_par = conn.execute(text(f"""
        SELECT COALESCE(sum(surface_m2),0)
        FROM {out} WHERE type_emplacement = 'parterre'""")).scalar()
    ecart = surf_par - SURFACE_PARTERRES_ATTENDUE
    print(f"  Surface parterres      : {surf_par:,.0f} m2".replace(",", " "))
    print(f"  Invariant attendu      : {SURFACE_PARTERRES_ATTENDUE:,.0f} m2".replace(",", " "))
    print(f"  Ecart                  : {ecart:,.2f} m2  "
          f"({'OK' if abs(ecart) < 1 else 'A VERIFIER'})".replace(",", " "))

    tp = conn.execute(text(f"""
        SELECT count(*), COALESCE(sum(surface_m2),0)
        FROM {out} WHERE type_emplacement = 'terre_plein'""")).fetchone()
    if not tp or not tp[0]:
        return

    print(f"  Terre-pleins           : {tp[0]:,} empl. / {tp[1]:,.0f} m2".replace(",", " "))
    print("  Mesure du chevauchement terre-pleins x parterres (dedupliquee)…")

    r = conn.execute(text(f"""
        WITH par_voisins AS (
            SELECT tp.id_emplacement, tp.geom AS geom_tp, tp.surface_m2 AS surf_tp,
                   ST_Union(pa.geom) AS union_parterres
            FROM {out} tp
            JOIN {out} pa ON pa.type_emplacement = 'parterre' AND ST_Intersects(tp.geom, pa.geom)
            WHERE tp.type_emplacement = 'terre_plein'
            GROUP BY tp.id_emplacement, tp.geom, tp.surface_m2
        ),
        mesure AS (
            SELECT id_emplacement, surf_tp,
                   ST_Area(ST_Intersection(geom_tp, union_parterres)) AS surf_couverte
            FROM par_voisins
        )
        SELECT count(*) AS n_avec_voisin,
               COALESCE(sum(surf_tp), 0) AS surf_tp_totale,
               COALESCE(sum(surf_couverte), 0) AS surf_couverte_totale,
               count(*) FILTER (WHERE surf_couverte / NULLIF(surf_tp, 0) >= :seuil) AS n_quasi_identiques
        FROM mesure
    """), {"seuil": SEUIL_QUASI_IDENTIQUE}).fetchone()

    n_avec_voisin, surf_tp_totale, surf_couverte_totale, n_quasi = r
    n_sans_voisin = tp[0] - n_avec_voisin
    ratio = (surf_couverte_totale / surf_tp_totale * 100) if surf_tp_totale else 0

    print(f"  Terre-pleins avec >=1 parterre voisin : {n_avec_voisin:,}".replace(",", " "))
    if n_sans_voisin:
        print(f"  Terre-pleins sans parterre voisin      : {n_sans_voisin:,}".replace(",", " "))
    print(f"  Chevauchement (dedupliquee)  : {surf_couverte_totale:,.0f} m2 "
          f"= {ratio:.1f} %".replace(",", " "))
    print(f"  Quasi identiques (>= {SEUIL_QUASI_IDENTIQUE*100:.0f} %) : "
          f"{n_quasi:,} / {tp[0]:,}".replace(",", " "))


def _qualifier(table):
    return f'"{SCHEMA_OUT}"."{table}"'


def creer_qa_terre_pleins(conn, out_brut):
    qa_all = _qualifier(TABLE_QA_TP_COUVERTURE)
    qa_inspecter = _qualifier(TABLE_QA_TP_A_INSPECTER)
    qa_doublons = _qualifier(TABLE_QA_TP_DOUBLONS)

    print("\n[QA] Diagnostic terre-pleins x parterres")
    for table in (qa_inspecter, qa_doublons, qa_all):
        conn.execute(text(f"DROP TABLE IF EXISTS {table} CASCADE"))

    conn.execute(text(f"""
        CREATE TABLE {qa_all} AS
        WITH tp AS (SELECT * FROM {out_brut} WHERE type_emplacement = 'terre_plein'),
        mesure AS (
            SELECT tp.id_emplacement, tp.id_troncon, tp.nom_rue,
                   tp.surface_m2 AS surf_tp_m2,
                   COALESCE(ST_Area(ST_Intersection(tp.geom, par.union_parterres)), 0) AS surf_couverte_m2,
                   tp.geom
            FROM tp
            LEFT JOIN LATERAL (
                SELECT ST_UnaryUnion(ST_Collect(pa.geom)) AS union_parterres
                FROM {out_brut} pa
                WHERE pa.type_emplacement = 'parterre'
                  AND pa.geom && tp.geom AND ST_Intersects(pa.geom, tp.geom)
            ) par ON true
        )
        SELECT id_emplacement, id_troncon, nom_rue, surf_tp_m2, surf_couverte_m2,
            GREATEST(surf_tp_m2 - surf_couverte_m2, 0) AS surf_non_couverte_m2,
            CASE WHEN surf_tp_m2 > 0 THEN surf_couverte_m2 / surf_tp_m2 ELSE 0 END AS ratio_couverture,
            CASE WHEN surf_tp_m2 > 0 AND surf_couverte_m2 / NULLIF(surf_tp_m2, 0) >= :seuil
                 THEN true ELSE false END AS est_quasi_identique,
            CASE
                WHEN surf_tp_m2 = 0 THEN 'surface_nulle'
                WHEN surf_couverte_m2 / NULLIF(surf_tp_m2, 0) >= :seuil THEN 'doublon_probable'
                WHEN surf_couverte_m2 / NULLIF(surf_tp_m2, 0) >= 0.50 THEN 'chevauchement_partiel'
                WHEN surf_couverte_m2 / NULLIF(surf_tp_m2, 0) > 0 THEN 'faible_chevauchement'
                ELSE 'distinct_sans_chevauchement'
            END AS diagnostic,
            geom
        FROM mesure
    """), {"seuil": SEUIL_QUASI_IDENTIQUE})

    conn.execute(text(f'ALTER TABLE {qa_all} ADD PRIMARY KEY (id_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {qa_all} USING GIST (geom)'))
    conn.execute(text(f'CREATE INDEX ON {qa_all} (diagnostic)'))
    conn.execute(text(f'CREATE INDEX ON {qa_all} (est_quasi_identique)'))

    conn.execute(text(f"""
        CREATE TABLE {qa_inspecter} AS
        SELECT * FROM {qa_all} WHERE est_quasi_identique = false
        ORDER BY ratio_couverture ASC, surf_tp_m2 DESC
    """))
    conn.execute(text(f'ALTER TABLE {qa_inspecter} ADD PRIMARY KEY (id_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {qa_inspecter} USING GIST (geom)'))
    conn.execute(text(f'CREATE INDEX ON {qa_inspecter} (diagnostic)'))

    conn.execute(text(f"""
        CREATE TABLE {qa_doublons} AS
        SELECT * FROM {qa_all} WHERE est_quasi_identique = true
        ORDER BY ratio_couverture DESC, surf_tp_m2 DESC
    """))
    conn.execute(text(f'ALTER TABLE {qa_doublons} ADD PRIMARY KEY (id_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {qa_doublons} USING GIST (geom)'))

    for table in (qa_all, qa_inspecter, qa_doublons):
        conn.execute(text(f'ANALYZE {table}'))

    total, doublons, a_inspecter = conn.execute(text(f"""
        SELECT count(*) AS total,
               count(*) FILTER (WHERE est_quasi_identique) AS doublons,
               count(*) FILTER (WHERE NOT est_quasi_identique) AS a_inspecter
        FROM {qa_all}
    """)).fetchone()

    print(f"  Terre-pleins analyses     : {total:,}".replace(",", " "))
    print(f"  Doublons probables exclus : {doublons:,}".replace(",", " "))
    print(f"  Cas a inspecter/conserver : {a_inspecter:,}".replace(",", " "))
    return qa_all, qa_inspecter, qa_doublons


def construire_maitresse_dedoublonnee(conn, out_brut, qa_all):
    out_final = _qualifier(TABLE_OUT_MAITRESSE)
    conn.execute(text(f"DROP TABLE IF EXISTS {out_final} CASCADE"))

    print("\n[CONSTRUCTION] Couche maitresse finale dedoublonnee")
    conn.execute(text(f"""
        CREATE TABLE {out_final} AS
        SELECT b.*,
            q.ratio_couverture AS ratio_couverture_parterres,
            q.diagnostic AS diagnostic_terre_plein,
            CASE
                WHEN b.type_emplacement = 'parterre' THEN 'conserve_parterre'
                WHEN b.type_emplacement = 'terre_plein'
                 AND COALESCE(q.est_quasi_identique, false) = false
                    THEN 'conserve_terre_plein_a_valider'
                ELSE 'conserve_autre'
            END AS statut_dedoublonnage
        FROM {out_brut} b
        LEFT JOIN {qa_all} q ON q.id_emplacement = b.id_emplacement
        WHERE b.type_emplacement <> 'terre_plein'
           OR COALESCE(q.est_quasi_identique, false) = false
        ORDER BY b.id_emplacement
    """))

    conn.execute(text(f'ALTER TABLE {out_final} ADD PRIMARY KEY (id_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {out_final} USING GIST (geom)'))
    conn.execute(text(f'CREATE INDEX ON {out_final} (id_troncon)'))
    conn.execute(text(f'CREATE INDEX ON {out_final} (type_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {out_final} (statut_dedoublonnage)'))
    conn.execute(text(f'ANALYZE {out_final}'))

    stats = conn.execute(text(f"""
        SELECT count(*) AS n_final,
               COALESCE(sum(surface_m2), 0) AS surface_finale,
               count(*) FILTER (WHERE type_emplacement = 'terre_plein') AS n_tp_final,
               COALESCE(sum(surface_m2) FILTER (WHERE type_emplacement = 'terre_plein'), 0) AS surf_tp_finale
        FROM {out_final}
    """)).fetchone()
    print(f"  Table finale             : {out_final}")
    print(f"  Entites finales          : {stats[0]:,}".replace(",", " "))
    print(f"  Surface totale finale    : {stats[1]:,.0f} m2".replace(",", " "))
    print(f"  Terre-pleins conserves   : {stats[2]:,} / {stats[3]:,.0f} m2".replace(",", " "))
    return out_final


def construire_livrable_filtre(conn, source_qualifie):
    out = _qualifier(TABLE_OUT_LIVRABLE)
    schema_s, table_s = source_qualifie.replace('"', "").split(".")
    dispo = [c for c, _ in colonnes(conn, schema_s, table_s)]
    dispo_low = {c.lower(): c for c in dispo}

    print("\n[LIVRABLE] Couche filtree (variables retenues)")
    if COLONNES_LIVRABLE is None:
        gardees = dispo
        manquantes = []
    else:
        gardees, manquantes = [], []
        for c in COLONNES_LIVRABLE:
            if c.lower() in dispo_low and dispo_low[c.lower()] not in gardees:
                gardees.append(dispo_low[c.lower()])
            elif c.lower() not in dispo_low:
                manquantes.append(c)
        if "geom" in dispo_low and dispo_low["geom"] not in gardees:
            gardees.append(dispo_low["geom"])

    sel = ", ".join(f'"{c}"' for c in gardees)
    conn.execute(text(f"DROP TABLE IF EXISTS {out} CASCADE"))
    conn.execute(text(f"CREATE TABLE {out} AS SELECT {sel} FROM {source_qualifie}"))
    if "id_emplacement" in dispo_low and dispo_low["id_emplacement"] in gardees:
        conn.execute(text(f'ALTER TABLE {out} ADD PRIMARY KEY (id_emplacement)'))
    if "geom" in dispo_low and dispo_low["geom"] in gardees:
        conn.execute(text(f'CREATE INDEX ON {out} USING GIST (geom)'))
    conn.execute(text(f'ANALYZE {out}'))

    print(f"  Table livrable           : {out}")
    print(f"  Variables conservees ({len(gardees)}) : {', '.join(gardees)}")
    if manquantes:
        print(f"  Demandees mais absentes ({len(manquantes)}) : {', '.join(manquantes)}")

    cols_mesure = [c for c in gardees if c.lower() != "geom"]
    if cols_mesure:
        sel = ", ".join(f'count("{c}") AS "{c}"' for c in cols_mesure)
        r = conn.execute(text(f'SELECT count(*) AS n_tot, {sel} FROM {out}')).mappings().fetchone()
        n = (r["n_tot"] or 1) if r else 1
        print("  Taux de remplissage (non NULL) :")
        vides = []
        for c in cols_mesure:
            rempli = (r[c] if r else 0) or 0
            pct = rempli / n * 100 if n else 0
            marque = "  <- VIDE (candidate au retrait)" if rempli == 0 else ""
            if rempli == 0:
                vides.append(c)
            print(f"    {c:26s} {pct:6.1f} %{marque}")
        if vides:
            print(f"  -> 100 % NULL : {', '.join(vides)}")
    return out


def construire_couche_controle_unique(conn, out_brut, qa_all):
    out_controle = _qualifier(TABLE_OUT_CONTROLE_UNIQUE)
    conn.execute(text(f"DROP TABLE IF EXISTS {out_controle} CASCADE"))

    print("\n[CONSTRUCTION] Couche unique de controle QGIS")
    conn.execute(text(f"""
        CREATE TABLE {out_controle} AS
        SELECT b.*,
            q.surf_tp_m2, q.surf_couverte_m2, q.surf_non_couverte_m2,
            q.ratio_couverture AS ratio_couverture_parterres,
            q.est_quasi_identique,
            q.diagnostic AS diagnostic_terre_plein,
            CASE
                WHEN b.type_emplacement = 'parterre' THEN true
                WHEN b.type_emplacement = 'terre_plein'
                 AND COALESCE(q.est_quasi_identique, false) = false THEN true
                ELSE false
            END AS inclure_livrable,
            CASE
                WHEN b.type_emplacement = 'parterre' THEN '01_parterre_conserve'
                WHEN b.type_emplacement = 'terre_plein'
                 AND COALESCE(q.est_quasi_identique, false) = false
                    THEN '02_terre_plein_conserve_a_inspecter'
                WHEN b.type_emplacement = 'terre_plein'
                 AND COALESCE(q.est_quasi_identique, false) = true
                    THEN '03_terre_plein_exclu_doublon'
                ELSE '99_autre'
            END AS statut_validation,
            CASE
                WHEN b.type_emplacement = 'parterre' THEN 'couche_maitresse'
                WHEN b.type_emplacement = 'terre_plein'
                 AND COALESCE(q.est_quasi_identique, false) = false
                    THEN 'qa_terre_pleins_a_inspecter'
                WHEN b.type_emplacement = 'terre_plein'
                 AND COALESCE(q.est_quasi_identique, false) = true
                    THEN 'qa_terre_pleins_doublons'
                ELSE 'autre'
            END AS couche_controle_source,
            CASE
                WHEN b.type_emplacement = 'parterre' THEN 'conserver dans le livrable final'
                WHEN b.type_emplacement = 'terre_plein'
                 AND COALESCE(q.est_quasi_identique, false) = false
                    THEN 'conserver provisoirement et valider visuellement'
                WHEN b.type_emplacement = 'terre_plein'
                 AND COALESCE(q.est_quasi_identique, false) = true
                    THEN 'exclure du livrable final pour eviter le double comptage'
                ELSE 'a verifier'
            END AS action_recommandee
        FROM {out_brut} b
        LEFT JOIN {qa_all} q ON q.id_emplacement = b.id_emplacement
        ORDER BY b.id_emplacement
    """))

    conn.execute(text(f'ALTER TABLE {out_controle} ADD PRIMARY KEY (id_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {out_controle} USING GIST (geom)'))
    conn.execute(text(f'CREATE INDEX ON {out_controle} (id_troncon)'))
    conn.execute(text(f'CREATE INDEX ON {out_controle} (type_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {out_controle} (inclure_livrable)'))
    conn.execute(text(f'CREATE INDEX ON {out_controle} (statut_validation)'))
    conn.execute(text(f'CREATE INDEX ON {out_controle} (couche_controle_source)'))
    conn.execute(text(f'ANALYZE {out_controle}'))

    print("  Repartition couche unique :")
    for r in conn.execute(text(f"""
        SELECT statut_validation, count(*) AS n, COALESCE(sum(surface_m2),0) AS surface_m2
        FROM {out_controle} GROUP BY statut_validation ORDER BY statut_validation
    """)):
        print(f"    {r[0]:38s} {r[1]:>8,} entites / {r[2]:,.0f} m2".replace(",", " "))

    print(f"  Table controle unique   : {out_controle}")
    return out_controle


def valider_finale(conn, out_final):
    print("\n[VALIDATION FINALE]")
    for r in conn.execute(text(f"""
        SELECT type_emplacement, count(*) AS n, COALESCE(sum(surface_m2),0) AS surface_m2
        FROM {out_final} GROUP BY type_emplacement ORDER BY type_emplacement
    """)):
        print(f"  {r[0]:15s} : {r[1]:>8,} entites / {r[2]:,.0f} m2".replace(",", " "))

    nb_a_valider = conn.execute(text(f"""
        SELECT count(*) FROM {out_final}
        WHERE statut_dedoublonnage = 'conserve_terre_plein_a_valider'
    """)).scalar()
    if nb_a_valider:
        print(f"  Attention : {nb_a_valider:,} terre-pleins distincts a valider dans "
              f"{SCHEMA_OUT}.{TABLE_QA_TP_A_INSPECTER}.".replace(",", " "))


def _ogr2ogr_supporte_postgresql():
    if not shutil.which("ogr2ogr"):
        return False
    try:
        r = subprocess.run(["ogr2ogr", "--formats"], text=True, capture_output=True, check=False)
        sortie = (r.stdout or "") + "\n" + (r.stderr or "")
        return "PostgreSQL" in sortie or "PostGIS" in sortie
    except Exception:
        return False


def _normaliser_colonnes_pour_gpkg(gdf):
    try:
        import json
        import pandas as pd
    except Exception:
        return gdf
    for col in list(gdf.columns):
        if col == gdf.geometry.name:
            continue
        if gdf[col].map(lambda v: isinstance(v, (dict, list))).any():
            gdf[col] = gdf[col].map(
                lambda v: json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v)
        if str(gdf[col].dtype) == "object":
            def conv(v):
                if v is None:
                    return None
                if isinstance(v, (str, int, float, bool)):
                    return v
                try:
                    if pd.isna(v):
                        return None
                except Exception:
                    pass
                return str(v)
            gdf[col] = gdf[col].map(conv)
    return gdf


def _chemin_gpkg():
    chemin = _resoudre_gpkg_path()
    return chemin if os.path.isabs(chemin) else os.path.join(_RACINE, chemin)


def _preparer_cible_gpkg(gpkg_path):
    if not os.path.exists(gpkg_path):
        return gpkg_path
    try:
        os.remove(gpkg_path)
        return gpkg_path
    except PermissionError:
        import datetime
        base, ext = os.path.splitext(gpkg_path)
        alt = f"{base}_{datetime.datetime.now():%Y%m%d_%H%M%S}{ext}"
        print(f"\n[EXPORT] ATTENTION : {gpkg_path} verrouille (QGIS ?).")
        print(f"         -> ecriture dans : {alt}")
        return alt


def _exporter_gpkg_geopandas(tables_qualifiees):
    try:
        import geopandas as gpd
    except Exception as e:
        print("\n[EXPORT] GeoPandas indisponible -> GeoPackage non cree.")
        print(f"         conda install -c conda-forge geopandas pyogrio  ({e})")
        return False

    gpkg_path = _chemin_gpkg()
    os.makedirs(os.path.dirname(gpkg_path) or ".", exist_ok=True)
    gpkg_path = _preparer_cible_gpkg(gpkg_path)

    print(f"\n[EXPORT] Repli GeoPandas. GeoPackage : {gpkg_path}")
    engine = creer_engine()
    for out_qualifie in tables_qualifiees:
        schema, table = out_qualifie.replace('"', "").split(".")
        sql = f'SELECT * FROM "{schema}"."{table}"'
        print(f"  - couche {table} <- {schema}.{table}")
        gdf = gpd.read_postgis(sql, engine, geom_col="geom")
        if gdf.crs is None:
            gdf = gdf.set_crs(epsg=SRID, allow_override=True)
        else:
            try:
                gdf = gdf.to_crs(epsg=SRID)
            except Exception:
                pass
        gdf = _normaliser_colonnes_pour_gpkg(gdf)
        gdf.to_file(gpkg_path, layer=table, driver="GPKG")
    print("[EXPORT] GeoPackage cree via GeoPandas.")
    return True


def exporter_gpkg(tables_qualifiees):
    if not EXPORT_GPKG:
        return
    if isinstance(tables_qualifiees, str):
        tables_qualifiees = [tables_qualifiees]

    p = _params_connexion()
    if p.get("url"):
        print("\n[EXPORT] connexion par URL -> GeoPandas.")
        _exporter_gpkg_geopandas(tables_qualifiees)
        return

    host = p.get("host") or "localhost"
    port = p.get("port") or "5432"
    db   = p.get("db") or "uti_montreal"
    user = p.get("user") or "ndoune"
    pwd  = p.get("pwd") or ""
    gpkg_path = _chemin_gpkg()
    os.makedirs(os.path.dirname(gpkg_path) or ".", exist_ok=True)

    if shutil.which("ogr2ogr") and _ogr2ogr_supporte_postgresql():
        gpkg_path = _preparer_cible_gpkg(gpkg_path)
        pg = f"PG:host={host} port={port} dbname={db} user={user} password={pwd}"
        print(f"\n[EXPORT] GeoPackage : {gpkg_path}")
        try:
            for i, out_qualifie in enumerate(tables_qualifiees):
                schema, table = out_qualifie.replace('"', "").split(".")
                cmd = ["ogr2ogr", "-f", "GPKG", gpkg_path, pg, f"{schema}.{table}",
                       "-nln", table, "-a_srs", f"EPSG:{SRID}"]
                cmd.append("-overwrite") if i == 0 else cmd.extend(["-update", "-overwrite"])
                print(f"  - couche {table} <- {schema}.{table}")
                subprocess.run(cmd, check=True)
            print("[EXPORT] GeoPackage cree via ogr2ogr.")
            return
        except subprocess.CalledProcessError as e:
            print(f"\n[EXPORT] ogr2ogr a echoue (code {e.returncode}). Repli GeoPandas.")
            _exporter_gpkg_geopandas(tables_qualifiees)
            return

    print("\n[EXPORT] ogr2ogr sans driver PostgreSQL -> repli GeoPandas.")
    _exporter_gpkg_geopandas(tables_qualifiees)


# -----------------------------------------------------------------------------
# 7. MAIN
# -----------------------------------------------------------------------------

def main():
    print("=" * 70)
    print(f"  Couche combinee UTI — mode = {MODE}")
    print("=" * 70)
    engine = creer_engine()
    sorties_export = []

    with engine.begin() as conn:
        print("[SCHEMA] Resolution des couches sources :")
        T = resoudre_tables(conn)

        if MODE == "maitresse":
            print("\n[CONSTRUCTION] Couche maitresse brute (epine = emplacements)")
            out_brut = construire_maitresse(conn, T)
            valider_maitresse(conn, out_brut)

            qa_all, qa_inspecter, qa_doublons = creer_qa_terre_pleins(conn, out_brut)
            out_final = construire_maitresse_dedoublonnee(conn, out_brut, qa_all)
            valider_finale(conn, out_final)
            out_livrable = construire_livrable_filtre(conn, out_final)
            out_controle_unique = construire_couche_controle_unique(conn, out_brut, qa_all)

            sorties_export = [out_livrable, out_controle_unique]

        elif MODE == "empilee":
            print("\n[CONSTRUCTION] Couche empilee (union heterogene)")
            out = construire_empilee(conn, T)
            sorties_export = [out]
        else:
            sys.exit(f"MODE inconnu : {MODE!r} (attendu 'maitresse' ou 'empilee')")

        for out in sorties_export:
            n = conn.execute(text(f"SELECT count(*) FROM {out}")).scalar()
            print(f"\n[OK] Table creee : {out}  ({n:,} entites)".replace(",", " "))

    exporter_gpkg(sorties_export)
    print("\nTermine.")


if __name__ == "__main__":
    main()