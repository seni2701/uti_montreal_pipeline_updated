-- ============================================================================
-- 12_interferences_documentation.sql   (RÉVISION post-chargement réel)
-- Livrable A — point D : RÉPERTOIRE DES INFRASTRUCTURES interférant avec
-- l'espace des tronçons (documentation, profil Gestionnaire).
--
-- Sources chargées (schéma raw) — noms de colonnes CONFIRMÉS via
-- information_schema (déjà passés en minuscules et TRONQUÉS à 10 car. par
-- le chargement shapefile) :
--   raw.signalisation_stationnement  (143 730)  code_rpa, fleche_pan, toponyme_p,
--                                     nom_arrond, poteau_id_, x, y, geometry
--   raw.collisions_routieres         (218 250)  gravite, dt_accdn, an, nb_victime,
--                                     loc_cote_q, loc_cote_p, geometry
--   raw.chantier_routier             (52)       entravetyp, entrave, debut, fin,
--                                     localisati, source, geometry
--   raw.poles                        (95 960)   id_trc, cote, nom_voie, geometry
--   uti.troncons_polygones                       id_trc, geom
--   uti.parterres                                id_treevans, id_trc, cote
--
-- ⚠️ REMARQUE CLÉ DE JOINTURE :
--   Le jeu « poteaux » chargé NE contient PAS de poteau_id_pot ; la liaison
--   panneau→poteau par identifiant est donc impossible ici. On rattache la
--   signalisation directement au TRONÇON par proximité spatiale (champ x/y),
--   ce qui suffit pour la documentation. Si un export ultérieur des poteaux
--   fournit poteau_id_pot, la jointure attributaire pourra remplacer le spatial.
-- ============================================================================

SET search_path = uti, raw, public;


DROP TABLE IF EXISTS uti.interferences_troncon;

CREATE TABLE uti.interferences_troncon (
    id_interf   bigserial PRIMARY KEY,
    categorie   text,      -- signalisation | collision | chantier
    sous_type   text,
    id_trc      bigint,
    cote        text,      -- côté/parité si disponible dans la source
    distance_m  numeric,
    details     jsonb,
    geom        geometry(Geometry, 2950)
);

-- ---------------------------------------------------------------------------
-- 1) Signalisation (stationnement sur rue) — 143 730 panneaux, points
--    Rattachement au tronçon le plus proche dans le rayon.
-- ---------------------------------------------------------------------------
INSERT INTO uti.interferences_troncon
    (categorie, sous_type, id_trc, cote, distance_m, details, geom)
SELECT 'signalisation',
       s.code_rpa,
       trc.id_trc,
       NULL,                                   -- pas de parité fiable côté panneau
       trc.dist,
       jsonb_build_object(
           'code_rpa',   s.code_rpa,
           'fleche',     s.fleche_pan,
           'toponyme',   s.toponyme_p,
           'arrond',     s.nom_arrond,
           'poteau_ref', s.poteau_id_          -- clé tronquée, conservée pour trace
       ),
       s.geom
FROM (
    SELECT code_rpa, fleche_pan, toponyme_p, nom_arrond, poteau_id_,
           geometry AS geom
    FROM raw.signalisation_stationnement
    WHERE geometry IS NOT NULL
) s
LEFT JOIN LATERAL (
    SELECT tp.id_trc, ST_Distance(s.geom, tp.geom) AS dist
    FROM uti.troncons_polygones tp
    WHERE ST_DWithin(s.geom, tp.geom, 15)
    ORDER BY s.geom <-> tp.geom
    LIMIT 1
) trc ON TRUE;

-- ---------------------------------------------------------------------------
-- 2) Collisions routières — points (11 nulles déjà écartées au chargement)
--    loc_cote_q / loc_cote_p = qualité / précision de localisation.
-- ---------------------------------------------------------------------------
INSERT INTO uti.interferences_troncon
    (categorie, sous_type, id_trc, cote, distance_m, details, geom)
SELECT 'collision',
       c.gravite,
       trc.id_trc,
       NULL,
       trc.dist,
       jsonb_build_object(
           'gravite',    c.gravite,
           'date',       c.dt_accdn,
           'annee',      c.an,
           'nb_victime', c.nb_victime,
           'loc_qual',   c.loc_cote_q,
           'loc_prec',   c.loc_cote_p
       ),
       c.geom
FROM (
    SELECT gravite, dt_accdn, an, nb_victime, loc_cote_q, loc_cote_p,
           geometry AS geom
    FROM raw.collisions_routieres
    WHERE geometry IS NOT NULL
) c
LEFT JOIN LATERAL (
    SELECT tp.id_trc, ST_Distance(c.geom, tp.geom) AS dist
    FROM uti.troncons_polygones tp
    WHERE ST_DWithin(c.geom, tp.geom, 15)
    ORDER BY c.geom <-> tp.geom
    LIMIT 1
) trc ON TRUE;

-- ---------------------------------------------------------------------------
-- 3) Chantiers / entraves — 52 entités (lignes ou polygones)
--    Rattachement par intersection directe ; repli proximité si non-couvrant.
-- ---------------------------------------------------------------------------
INSERT INTO uti.interferences_troncon
    (categorie, sous_type, id_trc, cote, distance_m, details, geom)
SELECT 'chantier',
       h.entravetyp,
       trc.id_trc,
       NULL,
       trc.dist,
       jsonb_build_object(
           'type_entrave', h.entravetyp,
           'entrave',      h.entrave,
           'debut',        h.debut,
           'fin',          h.fin,
           'localisation', h.localisati,
           'source',       h.source
       ),
       h.geom
FROM (
    SELECT entravetyp, entrave, debut, fin, localisati, source,
           ST_Multi(ST_MakeValid(geometry)) AS geom
    FROM raw.chantier_routier
    WHERE geometry IS NOT NULL
) h
LEFT JOIN LATERAL (
    SELECT tp.id_trc,
           CASE WHEN ST_Intersects(h.geom, tp.geom) THEN 0
                ELSE ST_Distance(h.geom, tp.geom) END AS dist
    FROM uti.troncons_polygones tp
    WHERE ST_DWithin(h.geom, tp.geom, 15)
    ORDER BY (NOT ST_Intersects(h.geom, tp.geom)), h.geom <-> tp.geom
    LIMIT 1
) trc ON TRUE;

-- ---------------------------------------------------------------------------
-- 4) Index
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_interf_geom ON uti.interferences_troncon USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_interf_trc  ON uti.interferences_troncon (id_trc);
CREATE INDEX IF NOT EXISTS idx_interf_cat  ON uti.interferences_troncon (categorie);
CREATE INDEX IF NOT EXISTS idx_interf_det  ON uti.interferences_troncon USING GIN (details);

-- Contrôles :
--   SELECT categorie, count(*), count(*) FILTER (WHERE id_trc IS NULL) AS non_rattaches
--   FROM uti.interferences_troncon GROUP BY 1;
--   SELECT id_trc, categorie, count(*) FROM uti.interferences_troncon
--   GROUP BY 1,2 ORDER BY 1 LIMIT 20;