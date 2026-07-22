#!/usr/bin/env python
# -*- coding: utf-8 -*-
# =============================================================================
#  couche_combinee_uti.py
#  ---------------------------------------------------------------------------
#  Consolidation de TOUTES les couches UTI (Livrable A) dans UNE seule couche.
#
#  Deux modes (flag MODE ci-dessous) :
#
#    MODE = "maitresse"  (defaut, recommande)
#        Couche denormalisee. L'epine spatiale est l'EMPLACEMENT
#        (parterres pair/impair + terre-pleins), l'unite atomique de l'UTI.
#        Chaque emplacement porte, par jointure spatiale ou attributaire,
#        toute l'information des autres couches :
#           - identite tronçon / UTG-A / arrondissement / rue
#           - adresses du tronçon (concatenees + nombre)
#           - lots riverains (concatenes + nombre)
#           - nb d'arbres, presence cyclable / ruelle verte,
#             nb de chantiers / interferences ponctuelles
#           - zonage dominant
#           - surface (m2)
#        -> Sortie : table polygonale  uti.couche_maitresse
#
#    MODE = "empilee"
#        Union heterogene : toutes les entites de toutes les couches
#        empilees telles quelles (points + lignes + polygones), avec un
#        discriminant "couche_source" et l'ensemble des attributs source
#        conserves dans une colonne JSONB "attributs" (aucune info perdue).
#        -> Sortie : table a geometrie generique  uti.couche_empilee
#
#  Convention CARTHAB : script NON destructif. Il ne modifie AUCUNE table
#  source ; il ne fait que CREATE / DROP sur sa table de sortie derivee.
#
#  Principe : PostGIS est la source de verite. Le schema reel est INSPECTE
#  au demarrage ; aucune colonne n'est presumee. Les couches ou colonnes
#  absentes sont ignorees avec un avertissement (comme le pipeline principal).
#
#  Execution :  python couche_combinee_uti.py
#  (les requetes SQL passent par SQLAlchemy, JAMAIS par psql en PowerShell)
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

SCHEMA_SRC = "uti"          # schema des couches sources
SCHEMA_OUT = "uti"          # schema de la table de sortie

TABLE_OUT_MAITRESSE = "couche_maitresse"
TABLE_OUT_EMPILEE   = "couche_empilee"

EXPORT_GPKG = False         # True -> tente un export ogr2ogr apres construction
GPKG_PATH   = r"data/processed/UTI_Couche_Combinee.gpkg"

# Surface totale attendue des parterres (invariant de partition Livrable A).
# Sert de simple controle de coherence, PAS d'assertion bloquante.
SURFACE_PARTERRES_ATTENDUE = 183_232_624  # m2

# Seuil (fraction de la surface d'un terre-plein) au-dela duquel on le
# considere quasi identique a un parterre deja existant dans la couche.
SEUIL_QUASI_IDENTIQUE = 0.95

# --- Cartographie logique des couches -> noms PostGIS reels ------------------
# Chaque entree liste des NOMS CANDIDATS ; le premier trouve dans le schema
# est retenu (resolution imprimee au runtime). Ajuster/completer au besoin.
TABLES_CANDIDATES = {
    "parterres":              ["parterres", "uti_parterres"],
    "terre_pleins":           ["terre_pleins", "uti_terre_pleins"],
    "troncons":               ["troncons_polygones", "troncons", "uti_troncons"],
    "adresses":               ["troncons_adresses", "adresses_troncon", "uti_adresses_troncon"],
    "lots":                   ["troncons_lots", "uti_troncons_lots"],
    "arbres":                 ["arbres", "uti_arbres"],
    "pistes_cyclables":       ["pistes_cyclables", "uti_pistes_cyclables"],
    "reseau_cyclable":        ["ref_reseau_cyclable", "reseau_cyclable"],
    "ruelles_vertes":         ["ref_ruelles_vertes", "ruelles_vertes"],
    "chantiers":              ["interferences_chantiers", "uti_interferences_chantiers"],
    "interf_ponctuelles":     ["interferences_ponctuelles", "uti_interferences_ponctuelles"],
    "composantes_voirie":     ["composantes_voirie", "uti_composantes_voirie"],
    "zonage":                 ["ref_zonage", "zonage"],
    "rues_limites_utg":       ["v_rues_limites_utg", "rues_limites_utg", "uti_rues_limites_utg"],
}

# Colonnes candidates pour certains attributs (resolues si presentes).
COL_COTE    = ["cote", "cote_rue", "parite"]           # 'pair' / 'impair'
COL_ID_TRC  = ["id_trc", "id_troncon", "no_troncon", "id_troncon_poly",
               "cle_troncon", "id", "gid", "objectid"]
COL_FK_TRC  = ["id_trc", "id_troncon", "troncon_id", "no_troncon",
               "id_troncon_poly", "cle_troncon", "gid_troncon"]
COL_ID_LOT  = ["no_lot", "numero_lot", "id_lot", "lot", "gid", "id"]
COL_RUE     = ["nom_rue", "rue", "nom_voie", "toponyme", "nom"]
COL_ZONAGE  = ["code_zonage", "zonage", "affectation", "usage", "categorie", "grande_affectation"]
COL_TYPE_CV = ["type", "type_composante", "categorie", "classe"]


# -----------------------------------------------------------------------------
# 2. CONNEXION
# -----------------------------------------------------------------------------

# La connexion s'aligne sur la config existante du pipeline. Ordre de lecture :
#   1) DATABASE_URL (ou equivalents) ;
#   2) variables d'environnement / .env, sous plusieurs noms de cles courants ;
#   3) section "database:" de config.yaml.
# Repertoire racine du projet (le script vit dans scripts/).
_RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _charger_dotenv():
    """Charge le .env du projet dans os.environ, sans ecraser l'existant."""
    try:
        from dotenv import load_dotenv  # optionnel
        for chemin in (os.path.join(_RACINE, ".env"), ".env"):
            if os.path.exists(chemin):
                load_dotenv(chemin)
        return
    except Exception:
        pass
    for chemin in (os.path.join(_RACINE, ".env"), ".env"):  # parseur minimal
        if os.path.exists(chemin):
            with open(chemin, encoding="utf-8") as f:
                for ligne in f:
                    ligne = ligne.strip()
                    if ligne and not ligne.startswith("#") and "=" in ligne:
                        k, v = ligne.split("=", 1)
                        os.environ.setdefault(k.strip(),
                                              v.strip().strip('"').strip("'"))


def _section_config_yaml():
    """Repli : retourne une section 'base de donnees' de config.yaml, ou {}."""
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


def _param(cands_env, cfg, cles_cfg, defaut=None):
    for k in cands_env:
        if os.environ.get(k):
            return os.environ[k]
    for k in cles_cfg:
        if cfg.get(k) not in (None, ""):
            return str(cfg[k])
    return defaut


def _params_connexion():
    """Resout les parametres de connexion depuis env / .env / config.yaml."""
    _charger_dotenv()
    for k in ("DATABASE_URL", "SQLALCHEMY_DATABASE_URI", "DB_URL"):
        if os.environ.get(k):
            return {"url": os.environ[k]}
    cfg = _section_config_yaml()
    return dict(
        host=_param(["PGHOST", "POSTGRES_HOST", "DB_HOST"], cfg,
                    ["host"], "localhost"),
        port=_param(["PGPORT", "POSTGRES_PORT", "DB_PORT"], cfg,
                    ["port"], "5432"),
        db=_param(["PGDATABASE", "POSTGRES_DB", "DB_NAME", "DB_DATABASE"], cfg,
                  ["dbname", "database", "name", "db"], "uti_montreal"),
        user=_param(["PGUSER", "POSTGRES_USER", "DB_USER"], cfg,
                    ["user", "username"], "ndoune"),
        pwd=_param(["PGPASSWORD", "POSTGRES_PASSWORD", "DB_PASSWORD", "DB_PASS"],
                   cfg, ["password", "pass", "pwd"], None),
    )


def creer_engine():
    from sqlalchemy import URL
    p = _params_connexion()
    # gssencmode=disable : coupe la negociation GSSAPI (source du bruit
    # "could not initiate GSSAPI security context" sous Windows).
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
            "  Verifie sous quel nom ton .env stocke le mot de passe, ou utilise l'une de :\n"
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
# 3. INSPECTION DU SCHEMA (rien n'est presume)
# -----------------------------------------------------------------------------

def tables_du_schema(conn, schema):
    q = text("""
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = :s
        UNION
        SELECT table_name
        FROM information_schema.views
        WHERE table_schema = :s
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
    """Retourne (nom_colonne_geom, srid) ou (None, None)."""
    q = text("""
        SELECT f_geometry_column, srid
        FROM geometry_columns
        WHERE f_table_schema = :s AND f_table_name = :t
        LIMIT 1
    """)
    r = conn.execute(q, {"s": schema, "t": table}).fetchone()
    if r:
        return r[0], r[1]
    # repli : colonne de type geometry non enregistree dans geometry_columns
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


def resoudre(candidats, disponibles):
    """Premier candidat present dans la liste disponible (insensible a la casse)."""
    bas = {d.lower(): d for d in disponibles}
    for c in candidats:
        if c.lower() in bas:
            return bas[c.lower()]
    return None


def cle_commune(conn, schema, table_a, table_b):
    """Deduit la cle de jointure = meilleure colonne commune (hors geom/cote/pk
    techniques). Retourne le nom (casse reelle de table_a) ou None."""
    cols_a = colonnes(conn, schema, table_a)           # [(nom, udt)]
    noms_b = {n.lower() for n, _ in colonnes(conn, schema, table_b)}
    bruit = {"geom", "geometry", "the_geom", "cote", "cote_rue", "parite",
             "gid", "fid", "objectid", "id", "surface", "surface_m2",
             "longueur", "geom_valide", "geom_source"}
    communs = [(n, u) for (n, u) in cols_a
               if n.lower() in noms_b and n.lower() not in bruit
               and u != "geometry"]
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


def resoudre_tables(conn):
    """Associe chaque cle logique a une table reelle du schema source."""
    presentes = tables_du_schema(conn, SCHEMA_SRC)
    resolues = {}
    for cle, cands in TABLES_CANDIDATES.items():
        t = resoudre(cands, presentes)
        resolues[cle] = t
        etat = t if t else "-- ABSENTE --"
        print(f"    [{cle:20s}] -> {etat}")
    return resolues


# -----------------------------------------------------------------------------
# 4. MODE MAITRESSE
# -----------------------------------------------------------------------------

def construire_maitresse(conn, T):
    out = f'"{SCHEMA_OUT}"."{TABLE_OUT_MAITRESSE}"'

    if not T["parterres"]:
        sys.exit("ERREUR : couche 'parterres' introuvable ; impossible de construire l'epine.")

    # -- 4.1 Epine : parterres (+ terre-pleins) ------------------------------
    g_par, _ = info_geom(conn, SCHEMA_SRC, T["parterres"])
    cols_par = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["parterres"])]
    col_cote = resoudre(COL_COTE, cols_par)
    key_par  = resoudre(COL_ID_TRC, cols_par)   # cle tronçon portee par le parterre

    print(f"  · epine       : {T['parterres']} (geom={g_par}, cote={col_cote or 'n/d'}, "
          f"id_troncon={key_par or 'n/d'})")

    sel_cote_par = f'p."{col_cote}"::text' if col_cote else "NULL::text"
    sel_key_par  = f'p."{key_par}"::text'  if key_par  else "NULL::text"

    parts = [f"""
        SELECT
            'parterre'::text                       AS type_emplacement,
            {sel_cote_par}                         AS cote,
            {sel_key_par}                          AS id_troncon,
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
            parts.append(f"""
                SELECT
                    'terre_plein'::text                    AS type_emplacement,
                    'central'::text                        AS cote,
                    {sel_key_tp}                           AS id_troncon,
                    ST_Multi(tp."{g_tp}")::geometry(MultiPolygon,{SRID}) AS geom
                FROM "{SCHEMA_SRC}"."{T['terre_pleins']}" tp
                WHERE tp."{g_tp}" IS NOT NULL
            """)
            print(f"  · terre-pleins: {T['terre_pleins']} inclus "
                  f"(id_troncon={key_tp or 'n/d'})")

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
            ST_Area(e.geom)                         AS surface_m2,
            e.geom
        FROM epine e
    """))
    conn.execute(text(f'ALTER TABLE {out} ADD PRIMARY KEY (id_emplacement)'))
    conn.execute(text(f'CREATE INDEX ON {out} USING GIST (geom)'))
    conn.execute(text(f'CREATE INDEX ON {out} (id_troncon)'))
    conn.execute(text(f'ANALYZE {out}'))

    n = conn.execute(text(f"SELECT count(*) FROM {out}")).scalar()
    n_lie = conn.execute(
        text(f"SELECT count(*) FROM {out} WHERE id_troncon IS NOT NULL")).scalar()
    print(f"  -> {n:,} emplacements ({n_lie:,} avec id_troncon)"
          .replace(",", " "))

    # -- 4.2 Attributs du tronçon (jointure attributaire par id_troncon) -----
    id_trc = None
    if T["troncons"]:
        g_trc, _ = info_geom(conn, SCHEMA_SRC, T["troncons"])
        cols_trc = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["troncons"])]
        id_trc = resoudre(COL_ID_TRC, cols_trc)
        col_rue = resoudre(COL_RUE, cols_trc)

        # Diagnostic : colonnes des deux tables charnieres.
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

        # Combien d'emplacements portent deja une cle tronçon (via l'epine) ?
        n_cle = conn.execute(
            text(f"SELECT count(*) FROM {out} WHERE id_troncon IS NOT NULL")).scalar()

        if id_trc and n_cle > 0:
            # Voie principale : jointure attributaire (fiable, contrairement au
            # spatial sur des parterres fins).
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
            # Repli : contenance spatiale (si aucune cle disponible).
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

    # -- 4.3 Adresses (jointure attributaire par id_troncon) -----------------
    # troncons_adresses = 1 ligne par tronçon (deja agregee). On copie donc les
    # colonnes utiles ; les plages civiques sont distribuees par cote :
    #   cote 'impair' -> deb_gch/fin_gch   |   cote 'pair' -> deb_drt/fin_drt
    #   (mapping valide : impair=gauche, pair=droite).
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

    # -- 4.4 Lots riverains (jointure spatiale ST_Intersects) ----------------
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

    # -- 4.5 Comptes / presences spatiales -----------------------------------
    _compte_spatial(conn, out, T, "arbres",             "nb_arbres",             "count")
    _compte_spatial(conn, out, T, "interf_ponctuelles", "nb_interf_ponctuelles", "count")
    _compte_spatial(conn, out, T, "chantiers",          "nb_chantiers",          "count")
    _compte_spatial(conn, out, T, "pistes_cyclables",   "a_piste_cyclable",      "bool")
    _compte_spatial(conn, out, T, "reseau_cyclable",    "a_reseau_cyclable",     "bool")
    _compte_spatial(conn, out, T, "ruelles_vertes",     "a_ruelle_verte",        "bool")

    # -- 4.6 Composantes voirie (aggregation des types) ----------------------
    if T["composantes_voirie"]:
        g_cv, _ = info_geom(conn, SCHEMA_SRC, T["composantes_voirie"])
        cols_cv = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["composantes_voirie"])]
        type_cv = resoudre(COL_TYPE_CV, cols_cv)
        if g_cv:
            conn.execute(text(f"ALTER TABLE {out} ADD COLUMN composantes_voirie text"))
            expr = (f"string_agg(DISTINCT cv.\"{type_cv}\"::text, ', ')"
                    if type_cv else "count(*)::text")
            conn.execute(text(f"""
                UPDATE {out} o SET composantes_voirie = s.v
                FROM (
                    SELECT o2.id_emplacement, {expr} AS v
                    FROM {out} o2
                    JOIN "{SCHEMA_SRC}"."{T['composantes_voirie']}" cv
                      ON ST_Intersects(cv."{g_cv}", o2.geom)
                    GROUP BY o2.id_emplacement
                ) s
                WHERE o.id_emplacement = s.id_emplacement
            """))
            print(f"  · comp. voirie: agregees (type={type_cv or 'nombre'})")

    # -- 4.7 Zonage dominant (contenance du point representatif) --------------
    if T["zonage"]:
        g_zon, _ = info_geom(conn, SCHEMA_SRC, T["zonage"])
        cols_zon = [c for c, _ in colonnes(conn, SCHEMA_SRC, T["zonage"])]
        col_zon  = resoudre(COL_ZONAGE, cols_zon)
        if g_zon and col_zon:
            conn.execute(text(f"ALTER TABLE {out} ADD COLUMN zonage_dominant text"))
            conn.execute(text(f"""
                UPDATE {out} o SET zonage_dominant = z."{col_zon}"::text
                FROM "{SCHEMA_SRC}"."{T['zonage']}" z
                WHERE ST_Contains(z."{g_zon}", ST_PointOnSurface(o.geom))
            """))
            print(f"  · zonage      : dominant (colonne={col_zon})")

    conn.execute(text(f"ANALYZE {out}"))
    return out


def _compte_spatial(conn, out, T, cle, col, mode):
    """Ajoute une colonne de comptage (count) ou de presence (bool) spatiale."""
    if not T.get(cle):
        return
    g_src, _ = info_geom(conn, SCHEMA_SRC, T[cle])
    if not g_src:
        return
    if mode == "bool":
        conn.execute(text(f"ALTER TABLE {out} ADD COLUMN {col} boolean DEFAULT false"))
        conn.execute(text(f"""
            UPDATE {out} o SET {col} = true
            WHERE EXISTS (
                SELECT 1 FROM "{SCHEMA_SRC}"."{T[cle]}" s
                WHERE ST_Intersects(s."{g_src}", o.geom)
            )
        """))
    else:  # count
        conn.execute(text(f"ALTER TABLE {out} ADD COLUMN {col} integer DEFAULT 0"))
        conn.execute(text(f"""
            UPDATE {out} o SET {col} = s.n
            FROM (
                SELECT o2.id_emplacement, count(*) AS n
                FROM {out} o2
                JOIN "{SCHEMA_SRC}"."{T[cle]}" s
                  ON ST_Intersects(s."{g_src}", o2.geom)
                GROUP BY o2.id_emplacement
            ) s
            WHERE o.id_emplacement = s.id_emplacement
        """))
    print(f"  · {cle:20s}: colonne {col} ({mode})")


# -----------------------------------------------------------------------------
# 5. MODE EMPILEE
# -----------------------------------------------------------------------------

def construire_empilee(conn, T):
    out = f'"{SCHEMA_OUT}"."{TABLE_OUT_EMPILEE}"'
    selects = []
    for cle, table in T.items():
        if not table:
            continue
        g, srid = info_geom(conn, SCHEMA_SRC, table)
        if g:
            geom_expr = (f'ST_Transform("{g}", {SRID})' if srid and srid != SRID
                         else f'"{g}"')
            geom_expr = f'ST_Multi({geom_expr})::geometry(Geometry,{SRID})'
            attrs = f'to_jsonb(t) - \'{g}\''
        else:  # table non spatiale (ex. adresses) : geom NULL, attributs conserves
            geom_expr = f'NULL::geometry(Geometry,{SRID})'
            attrs = "to_jsonb(t)"
        selects.append(f"""
            SELECT '{cle}'::text AS couche_source,
                   '{table}'::text AS table_source,
                   {attrs} AS attributs,
                   {geom_expr} AS geom
            FROM "{SCHEMA_SRC}"."{table}" t
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
    print(f"  Invariant attendu      : {SURFACE_PARTERRES_ATTENDUE:,.0f} m2"
          .replace(",", " "))
    print(f"  Ecart                  : {ecart:,.2f} m2  "
          f"({'OK' if abs(ecart) < 1 else 'A VERIFIER'})".replace(",", " "))

    # Note : les terre-pleins sont rapportes a part ; leur additivite a la
    # partition des parterres n'est pas presumee -> mesuree ci-dessous, avec
    # une deduplication (union prealable des parterres voisins) pour que le
    # ratio de recouvrement reste borne a 100 %.
    tp = conn.execute(text(f"""
        SELECT count(*), COALESCE(sum(surface_m2),0)
        FROM {out} WHERE type_emplacement = 'terre_plein'""")).fetchone()
    if not tp or not tp[0]:
        return

    print(f"  Terre-pleins           : {tp[0]:,} empl. / {tp[1]:,.0f} m2"
          .replace(",", " "))
    print("  Mesure du chevauchement terre-pleins x parterres "
          "(dedupliquee, peut prendre quelques secondes)…")

    r = conn.execute(text(f"""
        WITH par_voisins AS (
            SELECT tp.id_emplacement,
                   tp.geom                          AS geom_tp,
                   tp.surface_m2                    AS surf_tp,
                   ST_Union(pa.geom)                 AS union_parterres
            FROM {out} tp
            JOIN {out} pa
              ON pa.type_emplacement = 'parterre'
             AND ST_Intersects(tp.geom, pa.geom)
            WHERE tp.type_emplacement = 'terre_plein'
            GROUP BY tp.id_emplacement, tp.geom, tp.surface_m2
        ),
        mesure AS (
            SELECT id_emplacement,
                   surf_tp,
                   ST_Area(ST_Intersection(geom_tp, union_parterres)) AS surf_couverte
            FROM par_voisins
        )
        SELECT
            count(*)                                              AS n_avec_voisin,
            COALESCE(sum(surf_tp), 0)                              AS surf_tp_totale,
            COALESCE(sum(surf_couverte), 0)                        AS surf_couverte_totale,
            count(*) FILTER (
                WHERE surf_couverte / NULLIF(surf_tp, 0) >= :seuil
            )                                                       AS n_quasi_identiques
        FROM mesure
    """), {"seuil": SEUIL_QUASI_IDENTIQUE}).fetchone()

    n_avec_voisin, surf_tp_totale, surf_couverte_totale, n_quasi = r
    n_sans_voisin = tp[0] - n_avec_voisin
    ratio = (surf_couverte_totale / surf_tp_totale * 100) if surf_tp_totale else 0

    print(f"  Terre-pleins avec >=1 parterre voisin : {n_avec_voisin:,}"
          .replace(",", " "))
    if n_sans_voisin:
        print(f"  Terre-pleins sans parterre voisin      : {n_sans_voisin:,} "
              f"(aire hors partition parterres)".replace(",", " "))
    print(f"  Chevauchement (dedupliquee)  : {surf_couverte_totale:,.0f} m2 "
          f"= {ratio:.1f} % de l'aire terre-plein concernee".replace(",", " "))
    print(f"  Quasi identiques (>= {SEUIL_QUASI_IDENTIQUE*100:.0f} % couverts) : "
          f"{n_quasi:,} / {tp[0]:,}".replace(",", " "))

    if ratio >= 95:
        verdict = ("superposition quasi totale -> la grande majorite des "
                   "terre-pleins occupent une aire deja couverte par les "
                   "parterres (risque de double comptage surfacique si "
                   "additionnes ; a examiner terre-plein par terre-plein via "
                   "n_quasi_identiques)")
    elif ratio <= 5:
        verdict = ("quasi disjoints -> terre-pleins hors de la partition des "
                   "parterres (aire additionnelle a l'enveloppe des troncons "
                   "-> a expliquer)")
    else:
        verdict = "chevauchement partiel -> a examiner cas par cas"
    print(f"  Verdict                     : {verdict}")


def exporter_gpkg(out_qualifie):
    if not EXPORT_GPKG:
        return
    if not shutil.which("ogr2ogr"):
        print("\n[EXPORT] ogr2ogr introuvable -> exporter via 03_export_gpkg.py.")
        return
    p = _params_connexion()
    if p.get("url"):
        print("\n[EXPORT] connexion fournie par URL -> exporter via 03_export_gpkg.py.")
        return
    host = p.get("host") or "localhost"
    db   = p.get("db") or "uti_montreal"
    user = p.get("user") or "ndoune"
    pwd  = p.get("pwd") or ""
    schema, table = out_qualifie.replace('"', "").split(".")
    os.makedirs(os.path.dirname(GPKG_PATH) or ".", exist_ok=True)
    cmd = [
        "ogr2ogr", "-f", "GPKG", GPKG_PATH,
        f"PG:host={host} dbname={db} user={user} password={pwd}",
        f"{schema}.{table}", "-nln", table,
        "-a_srs", f"EPSG:{SRID}", "-overwrite",
    ]
    print(f"\n[EXPORT] {GPKG_PATH} <- {schema}.{table}")
    subprocess.run(cmd, check=True)


# -----------------------------------------------------------------------------
# 7. MAIN
# -----------------------------------------------------------------------------

def main():
    print("=" * 70)
    print(f"  Couche combinee UTI — mode = {MODE}")
    print("=" * 70)
    engine = creer_engine()
    with engine.begin() as conn:  # transaction : tout ou rien
        print("[SCHEMA] Resolution des couches sources :")
        T = resoudre_tables(conn)

        if MODE == "maitresse":
            print("\n[CONSTRUCTION] Couche maitresse (epine = emplacements)")
            out = construire_maitresse(conn, T)
            valider_maitresse(conn, out)
        elif MODE == "empilee":
            print("\n[CONSTRUCTION] Couche empilee (union heterogene)")
            out = construire_empilee(conn, T)
        else:
            sys.exit(f"MODE inconnu : {MODE!r} (attendu 'maitresse' ou 'empilee')")

        n = conn.execute(text(f"SELECT count(*) FROM {out}")).scalar()
        print(f"\n[OK] Table creee : {out}  ({n:,} entites)".replace(",", " "))

    exporter_gpkg(out)
    print("\nTermine.")


if __name__ == "__main__":
    main()