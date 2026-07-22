-- 05_surfaces_dimensions.sql
-- Livrable A — étape 5 : calcul surfaces et dimensions (EPSG:2950 = mètres)

ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS surface_m2     numeric;
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS longueur_axe_m numeric;
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS largeur_moy_m  numeric;

UPDATE uti.troncons_polygones
SET surface_m2     = ROUND(ST_Area(geom)::numeric, 2),
    longueur_axe_m = ROUND(ST_Length(axe)::numeric, 2),
    largeur_moy_m  = CASE
                       WHEN ST_Length(axe) > 0
                       THEN ROUND((ST_Area(geom) / ST_Length(axe))::numeric, 2)
                       ELSE NULL
                     END;

ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS surface_m2  numeric;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS perimetre_m numeric;

UPDATE uti.parterres
SET surface_m2  = ROUND(ST_Area(geom)::numeric, 2),
    perimetre_m = ROUND(ST_Perimeter(geom)::numeric, 2);

-- Recalcule les statistiques du planificateur après les UPDATE en masse
ANALYZE uti.troncons_polygones;
ANALYZE uti.parterres;

-- Contrôle 1 : tronçons avec surface nulle ou aberrante (> 10 000 m2)
SELECT id_trc, surface_m2, longueur_axe_m
FROM uti.troncons_polygones
WHERE surface_m2 IS NULL OR surface_m2 <= 0 OR surface_m2 > 10000;

-- Contrôle 2 : parterres "sliver", surface quasi nulle, probablement issus
-- d'un ST_Split degenere au script 03 (axe quasi tangent au bord du polygone).
-- A examiner avant livraison - candidat pour un futur 03b_fix_slivers.sql
-- selon la convention CARTHAB si le volume est significatif.
SELECT id_trc, demi_id, surface_m2, perimetre_m
FROM uti.parterres
WHERE surface_m2 < 0.5
ORDER BY surface_m2;