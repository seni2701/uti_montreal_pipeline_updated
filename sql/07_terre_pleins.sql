-- 07_terre_pleins.sql
-- Étape 2 : identification et matérialisation des terre-pleins
-- Source : raw.voirie_active
-- Colonne clé : TYPEILOT_R contient les valeurs de terre-plein
--
-- Valeurs terrain réelles dans TYPEILOT_R :
--   'Terre-plein central'              → le plus fréquent (3 838)
--   'Terre-plein latéral - cyclable'   → (2 432)
--   'Terre-plein central - autoroute'  → (737)
--   'Terre-plein latéral - voirie'     → (454)
--   'Terre-plein latéral - autoroute'  → (426)
--   'Ilot central', 'Ilot séparateur', etc. → inclus car séparent les chaussées

-- ── Étape 2a : extraire tous les terre-pleins de voirie_active ─────────────
DROP TABLE IF EXISTS uti.terre_pleins_source CASCADE;

CREATE TABLE uti.terre_pleins_source AS
SELECT
    id_voi_voi                          AS id_voirie,
    typeilot_r                          AS type_ilot,
    categoriec                          AS categorie,
    utilisatio                          AS utilisation,
    typeusagec                          AS usage_cyclable,
    presencear                          AS presence_arbre,
    ROUND(ST_Area(geometry)::numeric, 2) AS surface_m2,
    geometry                            AS geom
FROM raw.voirie_active
WHERE typeilot_r IN (
    'Terre-plein central',
    'Terre-plein central - autoroute',
    'Terre-plein latéral - cyclable',
    'Terre-plein latéral - voirie',
    'Terre-plein latéral - autoroute',
    'Ilot central',
    'Ilot central giratoire',
    'Ilot central - autoroute',
    'Ilot séparateur',
    'Ilot déviateur'
)
AND geometry IS NOT NULL;

CREATE INDEX idx_tp_source_geom ON uti.terre_pleins_source USING GIST (geom);

-- ── Étape 2b : rattacher chaque terre-plein à son tronçon ─────────────────
DROP TABLE IF EXISTS uti.terre_pleins CASCADE;

CREATE TABLE uti.terre_pleins AS
SELECT DISTINCT ON (tp.id_voirie)
    tp.id_voirie,
    tp.type_ilot,
    tp.categorie,
    tp.usage_cyclable,
    tp.presence_arbre,
    tp.surface_m2,
    t.id_trc,
    t.nom_rue,
    tp.geom
FROM uti.terre_pleins_source tp
JOIN uti.troncons_polygones t
    ON ST_Intersects(tp.geom, t.geom)
ORDER BY tp.id_voirie, ST_Area(ST_Intersection(tp.geom, t.geom)) DESC;

CREATE INDEX idx_tp_geom  ON uti.terre_pleins USING GIST (geom);
CREATE INDEX idx_tp_tronc ON uti.terre_pleins (id_trc);

-- ── Étape 2c : mettre à jour la table parterres (terre_plein = TRUE) ───────
-- On marque comme terre-plein les parterres dont la géométrie chevauche
-- significativement un terre-plein de voirie_active
UPDATE uti.parterres p
SET terre_plein = TRUE
FROM uti.terre_pleins tp
WHERE ST_Intersects(p.geom, tp.geom)
  AND ST_Area(ST_Intersection(p.geom, tp.geom)) / NULLIF(ST_Area(p.geom), 0) > 0.3;

-- ── Étape 2d : rapport de résultat ────────────────────────────────────────
-- SELECT type_ilot, count(*), ROUND(AVG(surface_m2)::numeric,1) AS surf_moy
-- FROM uti.terre_pleins GROUP BY type_ilot ORDER BY count(*) DESC;
--
-- SELECT count(*) FROM uti.parterres WHERE terre_plein = TRUE;