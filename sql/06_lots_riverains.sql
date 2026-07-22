-- 06_lots_riverains.sql
-- Étape 1 avancée : intégration des lots cadastraux riverains dans les polygones de rue
-- Cas ciblés : autoroutes, boulevards, avenues larges (surface > 1 500 m²)
-- Source : raw.cadastre (colonnes réelles : g_no_lot, g_co_type_, g_nm_circn, geometry)
--
-- Logique : un lot cadastral est "riverain" s'il touche un polygone de rue
-- ET que son centroïde ne tombe pas déjà dans ce polygone (il est adjacent, pas inclus).
-- On l'intègre au polygone de rue uniquement pour les voies à grande emprise.

-- ── Étape 1a : identifier les lots riverains candidats ─────────────────────
DROP TABLE IF EXISTS uti.lots_riverains_candidats CASCADE;

CREATE TABLE uti.lots_riverains_candidats AS
SELECT
    c.g_no_lot                          AS no_lot,
    c.g_co_type_                        AS type_lot,
    c.g_nm_circn                        AS arrondissement,
    ROUND(ST_Area(c.geometry)::numeric, 2) AS surface_m2,
    r.nom_rue,
    r.id_utg,
    c.geometry                          AS geom_lot,
    r.geom                              AS geom_rue
FROM raw.cadastre c
JOIN uti.rues_polygones r
    ON ST_Touches(c.geometry, r.geom)
    OR (ST_Intersects(c.geometry, r.geom)
        AND ST_Area(ST_Intersection(c.geometry, r.geom)) > 10)  -- chevauchement réel
WHERE
    -- Exclure les lots déjà entièrement dans le polygone de rue
    NOT ST_Within(c.geometry, r.geom)
    -- Cibler les grandes emprises (autoroutes, boulevards)
    AND ST_Area(c.geometry) > 500
    -- Exclure les lots manifestement bâtis (trop petits pour être de l'emprise)
    AND ST_Area(c.geometry) < 500000;

CREATE INDEX idx_lots_riverains_geom ON uti.lots_riverains_candidats USING GIST (geom_lot);

-- Contrôle : SELECT count(*), ROUND(AVG(surface_m2)::numeric,1) FROM uti.lots_riverains_candidats;

-- ── Étape 1b : fusionner les lots riverains dans les polygones de rue ───────
DROP TABLE IF EXISTS uti.rues_polygones_enrichies CASCADE;

CREATE TABLE uti.rues_polygones_enrichies AS
SELECT
    r.nom_rue,
    r.id_utg,
    r.nom_utg,
    ST_Multi(
        ST_Union(
            ARRAY[r.geom] ||
            ARRAY(
                SELECT l.geom_lot
                FROM uti.lots_riverains_candidats l
                WHERE l.nom_rue = r.nom_rue
                  AND l.id_utg  = r.id_utg
            )
        )
    )::geometry(MultiPolygon, 2950) AS geom,
    -- Méta
    (SELECT count(*) FROM uti.lots_riverains_candidats l
     WHERE l.nom_rue = r.nom_rue AND l.id_utg = r.id_utg) AS nb_lots_integres
FROM uti.rues_polygones r;

CREATE INDEX idx_rues_enrichies_geom ON uti.rues_polygones_enrichies USING GIST (geom);
CREATE INDEX idx_rues_enrichies_nom  ON uti.rues_polygones_enrichies (nom_rue);

-- Contrôle :
-- SELECT count(*) FROM uti.rues_polygones_enrichies WHERE nb_lots_integres > 0;
-- SELECT nom_rue, nb_lots_integres FROM uti.rues_polygones_enrichies
-- WHERE nb_lots_integres > 0 ORDER BY nb_lots_integres DESC LIMIT 20;