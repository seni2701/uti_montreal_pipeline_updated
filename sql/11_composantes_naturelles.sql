-- ============================================================================
-- 11_composantes_naturelles.sql   (noms RÉELS + blindage extrait corrompu)
-- Livrable A — COMPOSANTES NATURELLES : arbres publics rattachés à l'emplacement.
--
-- Source : raw.arbres_publics (colonne géométrie = "geometry", EPSG:2950)
--   Champs réels : emp_no, inv_type, essence_fr, dhp (TEXTE, sale),
--   arbre_rema (contaminé : plages horaires), emplacemen, rue_cote, no_civique, rue
--
-- ⚠️ QUALITÉ SOURCE : cet extrait (5 275 arbres) est DÉSALIGNÉ :
--   - dhp contient parfois des noms d'essences (ex. 'Plum') → extraction
--     numérique par regex, sinon NULL (évite l'échec de cast).
--   - arbre_rema contient des plages horaires → 'remarquable' laissé à NULL.
--   Re-télécharger l'inventaire consolidé complet dès que possible.
--
-- Tolérance de rattachement : 12 m (arbre de banquette hors parterre possible).
-- Le bloc « emplacements de plantation » est NEUTRALISÉ (source non chargée).
-- ============================================================================

SET search_path = uti, raw, public;

DROP TABLE IF EXISTS uti.arbres;

CREATE TABLE uti.arbres (
    id_arbre             bigserial PRIMARY KEY,
    emp_no               text,
    inv_type             text,
    essence              text,
    dhp_cm               numeric,
    remarquable          boolean,       -- laissé NULL (source contaminée)
    emplacement_src      text,
    cote_src             text,          -- N/S/E/O (source), non pair/impair
    no_civique           text,
    rue                  text,
    type_emplacement     text,          -- parterre | terre_plein | banquette | trottoir | autre
    id_trc               bigint,
    id_treevans          text,
    id_tp                bigint,
    methode_rattachement text,          -- contenu | proximite | non_rattache
    distance_m           numeric,
    geom                 geometry(Point, 2950)
);

INSERT INTO uti.arbres
    (emp_no, inv_type, essence, dhp_cm, remarquable,
     emplacement_src, cote_src, no_civique, rue,
     type_emplacement, id_trc, id_treevans, id_tp,
     methode_rattachement, distance_m, geom)
SELECT
    a.emp_no, a.inv_type, a.essence, a.dhp_cm, NULL::boolean,
    a.emplacement_src, a.cote_src, a.no_civique, a.rue,
    CASE
        WHEN a.emplacement_src ILIKE 'parterre%'         THEN 'parterre'
        WHEN a.emplacement_src ILIKE 'terre%plein%'      THEN 'terre_plein'
        WHEN a.emplacement_src ILIKE 'banquette%'        THEN 'banquette'
        WHEN a.emplacement_src ILIKE 'fond de trottoir%' THEN 'banquette'
        WHEN a.emplacement_src ILIKE 'trottoir%'         THEN 'trottoir'
        ELSE 'autre'
    END,
    par.id_trc,
    par.id_treevans,
    NULL::bigint,   -- id_tp neutralise (voir note)
    CASE
        WHEN par.id_treevans IS NOT NULL
             THEN CASE WHEN par.dist = 0 THEN 'contenu' ELSE 'proximite' END
        ELSE 'non_rattache'
    END,
    par.dist,
    a.geom
FROM (
    SELECT
        t.emp_no::text                              AS emp_no,
        NULLIF(t.inv_type,'')                       AS inv_type,
        NULLIF(t.essence_fr,'')                     AS essence,
        CASE WHEN t.dhp ~ '^[0-9]+(\.[0-9]+)?$'     -- extraction numerique sure
             THEN t.dhp::numeric END                AS dhp_cm,
        NULLIF(t.emplacemen,'')                     AS emplacement_src,
        NULLIF(t.rue_cote,'')                       AS cote_src,
        NULLIF(t.no_civique,'')                     AS no_civique,
        NULLIF(t.rue,'')                            AS rue,
        ST_Transform(t.geometry, 2950)              AS geom
    FROM raw.arbres_publics t
    WHERE t.geometry IS NOT NULL
) a
LEFT JOIN LATERAL (
    SELECT p.id_treevans, p.id_trc, ST_Distance(a.geom, p.geom) AS dist
    FROM uti.parterres p
    WHERE ST_DWithin(a.geom, p.geom, 12)
    ORDER BY a.geom <-> p.geom
    LIMIT 1
) par ON TRUE;
-- NOTE : rattachement terre-plein retire (uti.terre_pleins sans id_tp).
--        A reactiver une fois le vrai nom de cle connu.

-- Index
CREATE INDEX IF NOT EXISTS idx_arbres_geom     ON uti.arbres USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_arbres_treevans ON uti.arbres (id_treevans);
CREATE INDEX IF NOT EXISTS idx_arbres_trc      ON uti.arbres (id_trc);

-- ---------------------------------------------------------------------------
-- Emplacements de plantation — NEUTRALISÉ (raw.emplacements_plantation absent).
-- Réactiver après chargement de la source correspondante.
-- ---------------------------------------------------------------------------

-- Contrôles :
--   SELECT methode_rattachement, count(*) FROM uti.arbres GROUP BY 1;
--   SELECT type_emplacement, count(*) FROM uti.arbres GROUP BY 1 ORDER BY 2 DESC;
--   SELECT count(*) FILTER (WHERE dhp_cm IS NOT NULL) AS dhp_valides,
--          count(*) AS total FROM uti.arbres;