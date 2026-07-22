-- =====================================================================
-- 14d_fix_arbres_hors_emprise.sql
-- POINT 4 — Composantes naturelles (famille routiere, point D).
-- 19 arbres tombent hors de l'emprise MTM8 (diagnostic [F3]) : symptome
-- classique d'inversion X<->Y ou de parsing errone du CSV source
-- (chargement depuis Coord_X / Coord_Y).
--
-- Strategie NON DESTRUCTIVE, en deux temps automatiques :
--   1) si permuter X et Y ramene le point dans l'emprise -> CORRIGER (recuperation)
--   2) sinon -> MARQUER hors_emprise = true (on n'efface jamais la ligne)
-- Convention CARTHAB : fichier suffixe, aucun script numerote modifie.
-- Runner SQLAlchemy : une instruction par ligne (pas de bloc DO).
-- =====================================================================

-- Drapeau de tracabilite (idempotent)
ALTER TABLE uti.arbres ADD COLUMN IF NOT EXISTS hors_emprise boolean DEFAULT false;
ALTER TABLE uti.arbres ADD COLUMN IF NOT EXISTS geom_source geometry(Point, 2950);

-- Sauvegarde de la geometrie d'origine AVANT toute correction (auditabilite)
UPDATE uti.arbres
SET geom_source = geom
WHERE (ST_X(geom) NOT BETWEEN 260000 AND 320000
    OR ST_Y(geom) NOT BETWEEN 5010000 AND 5075000)
  AND geom_source IS NULL;

-- 1) CORRECTION des inversions X<->Y : permuter ramene le point dans l'emprise
UPDATE uti.arbres
SET geom = ST_SetSRID(ST_MakePoint(ST_Y(geom), ST_X(geom)), 2950)
WHERE (ST_X(geom) NOT BETWEEN 260000 AND 320000
    OR ST_Y(geom) NOT BETWEEN 5010000 AND 5075000)
  AND ST_Y(geom) BETWEEN 260000 AND 320000
  AND ST_X(geom) BETWEEN 5010000 AND 5075000;

-- 2) MARQUAGE des points reellement aberrants (non recuperables par permutation)
UPDATE uti.arbres
SET hors_emprise = true
WHERE ST_X(geom) NOT BETWEEN 260000 AND 320000
   OR ST_Y(geom) NOT BETWEEN 5010000 AND 5075000;

-- Controle (a lire via diagnostic_uti.py [F3] ou un client SQL) :
--   SELECT count(*) FILTER (WHERE hors_emprise) AS restants_aberrants,
--          count(*) FILTER (WHERE geom_source IS NOT NULL) AS traites
--   FROM uti.arbres;
-- Attendu : [F3] du diagnostic doit fortement diminuer (idealement 0 si toutes
-- les 19 anomalies etaient des inversions X<->Y recuperables).
