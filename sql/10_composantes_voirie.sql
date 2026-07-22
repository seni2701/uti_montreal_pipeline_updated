-- ============================================================================
-- 10_composantes_voirie.sql   (noms de colonnes RÉELS confirmés via .dbf)
-- Livrable A — COMPOSANTES INFRASTRUCTURELLES : trottoir / îlot (+ chaussée opt.)
-- et réseau cyclable, rattachés au tronçon puis au parterre.
--
-- Sources (schéma raw ; colonne géométrie = "geometry", déjà en EPSG:2950) :
--   raw.voirie_active     discriminant = actif_voir (VOI_TROTTOIR_/CHAUSSEE_/ILOT_/…)
--                         saillie_re, typetrotto, typebordur, typeusagec,
--                         presencear ('Oui'/'Non'/…), categoriec, categoriet,
--                         materiautr/ch/il/bo…
--   raw.reseau_cyclable   id_trc (0 = non rattaché), type_voie_, separateur,
--                         protege_4s, route_vert
--   uti.troncons_polygones (id_trc, geom) ; uti.parterres (id_treevans, id_trc, geom)
--
-- Note perf : par défaut on ne charge que TROTTOIR + ÎLOT (utiles aux parterres).
-- La chaussée (secondaire au mandat, polygones lourds) est en bloc optionnel.
-- ============================================================================

SET search_path = uti, raw, public;

-- ---------------------------------------------------------------------------
-- 1) Composantes de voirie (trottoir + îlot)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS uti.composantes_voirie;

CREATE TABLE uti.composantes_voirie (
    id_composante   bigserial PRIMARY KEY,
    type_composante text,      -- trottoir | ilot | chaussee
    categorie       text,      -- Rue/Ruelle/Autoroute… (chaussée) ou Trottoir/Bordure
    type_trottoir   text,
    type_bordure    text,
    usage_cyclable  text,
    saillie         text,      -- 'Oui' / 'Non'
    presence_arbre  text,      -- 'Oui' / 'Non' / 'Non applicable' / 'Inconnu'
    materiau        text,
    id_trc          bigint,
    id_treevans     text,
    surface_m2      numeric,
    geom            geometry(MultiPolygon, 2950)
);

INSERT INTO uti.composantes_voirie
    (type_composante, categorie, type_trottoir, type_bordure, usage_cyclable,
     saillie, presence_arbre, materiau, id_trc, id_treevans, surface_m2, geom)
SELECT
    v.type_composante, v.categorie, v.type_trottoir, v.type_bordure, v.usage_cyclable,
    v.saillie, v.presence_arbre, v.materiau,
    trc.id_trc, par.id_treevans, ST_Area(v.geom), v.geom
FROM (
    SELECT
        CASE
            WHEN t.actif_voir LIKE 'VOI_TROTTOIR%' THEN 'trottoir'
            WHEN t.actif_voir LIKE 'VOI_ILOT%'     THEN 'ilot'
            WHEN t.actif_voir LIKE 'VOI_CHAUSSEE%' THEN 'chaussee'
            ELSE lower(t.actif_voir)
        END                                                     AS type_composante,
        COALESCE(NULLIF(t.categoriet,''), NULLIF(t.categoriec,'')) AS categorie,
        NULLIF(t.typetrotto,'')                                 AS type_trottoir,
        NULLIF(t.typebordur,'')                                 AS type_bordure,
        NULLIF(t.typeusagec,'')                                 AS usage_cyclable,
        NULLIF(t.saillie_re,'')                                 AS saillie,
        NULLIF(t.presencear,'')                                 AS presence_arbre,
        COALESCE(NULLIF(t.materiautr,''), NULLIF(t.materiauch,''),
                 NULLIF(t.materiauil,''), NULLIF(t.materiaubo,'')) AS materiau,
        ST_Multi(ST_CollectionExtract(ST_MakeValid(t.geometry), 3)) AS geom
    FROM raw.voirie_active t
    WHERE t.geometry IS NOT NULL
      AND (t.actif_voir LIKE 'VOI_TROTTOIR%' OR t.actif_voir LIKE 'VOI_ILOT%')
) v
LEFT JOIN LATERAL (
    SELECT tp.id_trc
    FROM uti.troncons_polygones tp
    WHERE ST_Intersects(v.geom, tp.geom)
    ORDER BY ST_Area(ST_Intersection(v.geom, tp.geom)) DESC
    LIMIT 1
) trc ON TRUE
LEFT JOIN LATERAL (
    SELECT p.id_treevans
    FROM uti.parterres p
    WHERE p.id_trc = trc.id_trc
      AND ST_Intersects(v.geom, p.geom)
    ORDER BY ST_Area(ST_Intersection(v.geom, p.geom)) DESC
    LIMIT 1
) par ON TRUE;

-- Chaussée (secondaire) — décommenter au besoin (lourd : gros polygones) :
-- INSERT INTO uti.composantes_voirie
--     (type_composante, categorie, materiau, id_trc, surface_m2, geom)
-- SELECT 'chaussee',
--        COALESCE(NULLIF(t.categoriec,''), NULLIF(t.categoriet,'')),
--        NULLIF(t.materiauch,''),
--        trc.id_trc, ST_Area(g.geom), g.geom
-- FROM (SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(geometry),3)) geom,
--              categoriec, categoriet, materiauch
--       FROM raw.voirie_active
--       WHERE geometry IS NOT NULL AND actif_voir LIKE 'VOI_CHAUSSEE%') AS t
-- CROSS JOIN LATERAL (SELECT t.geom) g
-- LEFT JOIN LATERAL (
--     SELECT tp.id_trc FROM uti.troncons_polygones tp
--     WHERE ST_Intersects(g.geom, tp.geom)
--     ORDER BY ST_Area(ST_Intersection(g.geom, tp.geom)) DESC LIMIT 1
-- ) trc ON TRUE;

-- ---------------------------------------------------------------------------
-- 2) Réseau cyclable — jointure directe par id_trc (repli spatial si id_trc=0)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS uti.pistes_cyclables;

CREATE TABLE uti.pistes_cyclables (
    id_cyclable          bigserial PRIMARY KEY,
    type_amenagement     text,     -- code type_voie_ (1..9)
    separateur           text,
    protege_4s           text,
    route_verte          text,
    longueur_m           numeric,
    id_trc               bigint,
    methode_rattachement text,     -- id_trc | spatial | non_rattache
    geom                 geometry(MultiLineString, 2950)
);

INSERT INTO uti.pistes_cyclables
    (type_amenagement, separateur, protege_4s, route_verte,
     longueur_m, id_trc, methode_rattachement, geom)
SELECT
    c.type_amenagement, c.separateur, c.protege_4s, c.route_verte,
    ST_Length(c.geom),
    COALESCE(c.id_trc, t2.id_trc),
    CASE WHEN c.id_trc IS NOT NULL THEN 'id_trc'
         WHEN t2.id_trc IS NOT NULL THEN 'spatial'
         ELSE 'non_rattache' END,
    c.geom
FROM (
    SELECT
        NULLIF(t.type_voie_,'')                       AS type_amenagement,
        NULLIF(t.separateur,'')                       AS separateur,
        NULLIF(t.protege_4s,'')                       AS protege_4s,
        NULLIF(t.route_vert,'')                       AS route_verte,
        CASE WHEN t.id_trc > 0 THEN t.id_trc::bigint END AS id_trc,
        ST_Multi(ST_MakeValid(t.geometry))            AS geom
    FROM raw.reseau_cyclable t
    WHERE t.geometry IS NOT NULL
) c
LEFT JOIN LATERAL (
    SELECT tp.id_trc
    FROM uti.troncons_polygones tp
    WHERE c.id_trc IS NULL
      AND ST_DWithin(c.geom, tp.geom, 5)
    ORDER BY c.geom <-> tp.geom
    LIMIT 1
) t2 ON TRUE;

-- ---------------------------------------------------------------------------
-- 3) Index
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_composantes_voirie_geom ON uti.composantes_voirie USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_composantes_voirie_trc  ON uti.composantes_voirie (id_trc);
CREATE INDEX IF NOT EXISTS idx_composantes_voirie_type ON uti.composantes_voirie (type_composante);
CREATE INDEX IF NOT EXISTS idx_pistes_cyclables_geom   ON uti.pistes_cyclables USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_pistes_cyclables_trc    ON uti.pistes_cyclables (id_trc);

-- Contrôles :
--   SELECT type_composante, count(*) FROM uti.composantes_voirie GROUP BY 1;
--   SELECT saillie, count(*) FROM uti.composantes_voirie GROUP BY 1;
--   SELECT methode_rattachement, count(*) FROM uti.pistes_cyclables GROUP BY 1;