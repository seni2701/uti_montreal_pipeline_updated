-- =====================================================================
-- 14b_fix_geometries_invalides.sql
-- Assainissement geometrique NON DESTRUCTIF du schema uti.
-- Ecrit dans une colonne parallele geom_valide ; la colonne geom d'origine
-- n'est JAMAIS ecrasee par ce script. La promotion geom_valide -> geom est
-- une etape separee et deliberee (voir bloc final commente).
-- Convention CARTHAB : fichier suffixe, aucun script numerote modifie.
-- Runner SQLAlchemy : valeurs litterales uniquement.
--
-- PREREQUIS : avoir execute 14a et statue sur le GATE [C].
--   - Si [C] montre un heritage dominant (ko_sous_troncon_ko) : NE PAS se
--     contenter de ce script. Assainir les troncons ici, puis REGENERER
--     parterres/terre-pleins (scripts 02b/03b) au lieu du ST_MakeValid aval.
--   - Le CONTROLE FINAL ci-dessous bloque la promotion si l'invariant
--     d'aire est rompu : c'est le signal de bascule vers la regeneration.
-- ---------------------------------------------------------------------
-- A CONFIRMER : memes noms de tables/colonnes que 14a. Types geometrie :
--   rues_polygones / troncons / composantes_voirie = (Multi)Polygon
--   parterres / terre_pleins                        = Polygon
--   interferences_troncon                           = geometrie MIXTE (points + lignes)
-- =====================================================================


-- [0] Journal de correction --------------------------------------------
CREATE TABLE IF NOT EXISTS uti.log_correction_14b (
  couche         text,
  n_total        bigint,
  n_invalides_av bigint,
  n_corrigees    bigint,
  n_invalides_ap bigint,
  n_vides_ap     bigint,
  aire_avant     numeric,
  aire_apres     numeric,
  horodatage     timestamptz DEFAULT now()
);


-- ---------------------------------------------------------------------
-- [1] Polygones nominatifs de rue (niveau UTI - contenant)
-- ---------------------------------------------------------------------
ALTER TABLE uti.rues_polygones ADD COLUMN IF NOT EXISTS geom_valide geometry(MultiPolygon, 2950);

UPDATE uti.rues_polygones
SET geom_valide = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);

UPDATE uti.rues_polygones
SET geom_valide = geom
WHERE ST_IsValid(geom) AND geom_valide IS NULL;

INSERT INTO uti.log_correction_14b
  (couche, n_total, n_invalides_av, n_corrigees, n_invalides_ap, n_vides_ap, aire_avant, aire_apres)
SELECT 'rues_polygones', count(*),
       count(*) FILTER (WHERE NOT ST_IsValid(geom)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom) AND geom_valide IS NOT NULL AND NOT ST_IsEmpty(geom_valide)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom_valide)),
       count(*) FILTER (WHERE ST_IsEmpty(geom_valide)),
       round(sum(ST_Area(geom))::numeric, 2),
       round(sum(ST_Area(geom_valide))::numeric, 2)
FROM uti.rues_polygones;


-- ---------------------------------------------------------------------
-- [2] Troncons surfaciques (niveau tronçon) -- corrige AUSSI la couche
--     exportee UTI_adresses_troncon, qui partage la meme table source.
-- ---------------------------------------------------------------------
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS geom_valide geometry(MultiPolygon, 2950);

UPDATE uti.troncons_polygones
SET geom_valide = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);

UPDATE uti.troncons_polygones
SET geom_valide = geom
WHERE ST_IsValid(geom) AND geom_valide IS NULL;

INSERT INTO uti.log_correction_14b
  (couche, n_total, n_invalides_av, n_corrigees, n_invalides_ap, n_vides_ap, aire_avant, aire_apres)
SELECT 'troncons', count(*),
       count(*) FILTER (WHERE NOT ST_IsValid(geom)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom) AND geom_valide IS NOT NULL AND NOT ST_IsEmpty(geom_valide)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom_valide)),
       count(*) FILTER (WHERE ST_IsEmpty(geom_valide)),
       round(sum(ST_Area(geom))::numeric, 2),
       round(sum(ST_Area(geom_valide))::numeric, 2)
FROM uti.troncons_polygones;


-- ---------------------------------------------------------------------
-- [3] Parterres (emplacement) -- geom_valide en MultiPolygon pour absorber
--     un eventuel eclatement ; un multipart sera signale au controle final.
-- ---------------------------------------------------------------------
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS geom_valide geometry(MultiPolygon, 2950);

UPDATE uti.parterres
SET geom_valide = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);

UPDATE uti.parterres
SET geom_valide = ST_Multi(geom)
WHERE ST_IsValid(geom) AND geom_valide IS NULL;

INSERT INTO uti.log_correction_14b
  (couche, n_total, n_invalides_av, n_corrigees, n_invalides_ap, n_vides_ap, aire_avant, aire_apres)
SELECT 'parterres', count(*),
       count(*) FILTER (WHERE NOT ST_IsValid(geom)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom) AND geom_valide IS NOT NULL AND NOT ST_IsEmpty(geom_valide)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom_valide)),
       count(*) FILTER (WHERE ST_IsEmpty(geom_valide)),
       round(sum(ST_Area(geom))::numeric, 2),
       round(sum(ST_Area(geom_valide))::numeric, 2)
FROM uti.parterres;


-- ---------------------------------------------------------------------
-- [4] Terre-pleins (emplacement)
-- ---------------------------------------------------------------------
ALTER TABLE uti.terre_pleins ADD COLUMN IF NOT EXISTS geom_valide geometry(MultiPolygon, 2950);

UPDATE uti.terre_pleins
SET geom_valide = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);

UPDATE uti.terre_pleins
SET geom_valide = ST_Multi(geom)
WHERE ST_IsValid(geom) AND geom_valide IS NULL;

INSERT INTO uti.log_correction_14b
  (couche, n_total, n_invalides_av, n_corrigees, n_invalides_ap, n_vides_ap, aire_avant, aire_apres)
SELECT 'terre_pleins', count(*),
       count(*) FILTER (WHERE NOT ST_IsValid(geom)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom) AND geom_valide IS NOT NULL AND NOT ST_IsEmpty(geom_valide)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom_valide)),
       count(*) FILTER (WHERE ST_IsEmpty(geom_valide)),
       round(sum(ST_Area(geom))::numeric, 2),
       round(sum(ST_Area(geom_valide))::numeric, 2)
FROM uti.terre_pleins;


-- ---------------------------------------------------------------------
-- [5] Composantes de voirie (infrastructure)
-- ---------------------------------------------------------------------
ALTER TABLE uti.composantes_voirie ADD COLUMN IF NOT EXISTS geom_valide geometry(MultiPolygon, 2950);

UPDATE uti.composantes_voirie
SET geom_valide = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);

UPDATE uti.composantes_voirie
SET geom_valide = geom
WHERE ST_IsValid(geom) AND geom_valide IS NULL;

INSERT INTO uti.log_correction_14b
  (couche, n_total, n_invalides_av, n_corrigees, n_invalides_ap, n_vides_ap, aire_avant, aire_apres)
SELECT 'composantes_voirie', count(*),
       count(*) FILTER (WHERE NOT ST_IsValid(geom)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom) AND geom_valide IS NOT NULL AND NOT ST_IsEmpty(geom_valide)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom_valide)),
       count(*) FILTER (WHERE ST_IsEmpty(geom_valide)),
       round(sum(ST_Area(geom))::numeric, 2),
       round(sum(ST_Area(geom_valide))::numeric, 2)
FROM uti.composantes_voirie;


-- ---------------------------------------------------------------------
-- [6] Interferences (chantiers lineaires) -- table a geometrie MIXTE.
--     geom_valide en type generique pour ne pas heurter les points.
--     ST_CollectionExtract(...,2) = ne garder que le lineaire assaini.
-- ---------------------------------------------------------------------
ALTER TABLE uti.interferences_troncon ADD COLUMN IF NOT EXISTS geom_valide geometry;

UPDATE uti.interferences_troncon
SET geom_valide = CASE
      WHEN ST_Dimension(geom) = 1
        THEN ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 2))
      ELSE ST_MakeValid(geom)   -- points : MakeValid est neutre
    END
WHERE NOT ST_IsValid(geom);

UPDATE uti.interferences_troncon
SET geom_valide = geom
WHERE ST_IsValid(geom) AND geom_valide IS NULL;

INSERT INTO uti.log_correction_14b
  (couche, n_total, n_invalides_av, n_corrigees, n_invalides_ap, n_vides_ap, aire_avant, aire_apres)
SELECT 'interferences', count(*),
       count(*) FILTER (WHERE NOT ST_IsValid(geom)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom) AND geom_valide IS NOT NULL AND NOT ST_IsEmpty(geom_valide)),
       count(*) FILTER (WHERE NOT ST_IsValid(geom_valide)),
       count(*) FILTER (WHERE ST_IsEmpty(geom_valide)),
       NULL, NULL
FROM uti.interferences_troncon;


-- =====================================================================
-- CONTROLE FINAL -- A LIRE AVANT TOUTE PROMOTION geom_valide -> geom
-- =====================================================================

-- (1) Plus aucune invalidite ni geometrie vide residuelle
SELECT couche, n_invalides_av, n_corrigees, n_invalides_ap, n_vides_ap
FROM uti.log_correction_14b
ORDER BY horodatage DESC;
-- Attendu : n_invalides_ap = 0 ET n_vides_ap = 0 pour TOUTES les couches.

-- (2) Invariant d'aire troncons = parterres (juge de paix)
SELECT
  (SELECT round(sum(ST_Area(geom_valide))::numeric, 2) FROM uti.troncons_polygones)  AS aire_troncons_ap,
  (SELECT round(sum(ST_Area(geom_valide))::numeric, 2) FROM uti.parterres) AS aire_parterres_ap,
  abs( (SELECT sum(ST_Area(geom_valide)) FROM uti.troncons_polygones)
     - (SELECT sum(ST_Area(geom_valide)) FROM uti.parterres) ) AS ecart_absolu;
-- Attendu : ecart_absolu proche de 0 (quelques m2 max).
-- Sinon : NE PAS PROMOUVOIR. Basculer vers la regeneration (02b/03b).

-- (3) Parterres eclates en multipart (artefact de decoupe a examiner)
SELECT count(*) AS parterres_scindes
FROM uti.parterres
WHERE ST_NumGeometries(geom_valide) > 1;
-- Attendu : 0. Un parterre = partition simple d'un troncon.


-- =====================================================================
-- PROMOTION (etape separee, a decommenter SEULEMENT si (1)(2)(3) sont verts)
-- Elle reste non destructive tant que geom_source n'est pas supprimee.
-- =====================================================================
-- ALTER TABLE uti.parterres          ADD COLUMN IF NOT EXISTS geom_source geometry;
-- UPDATE uti.parterres          SET geom_source = geom, geom = geom_valide;
-- (repeter le meme motif geom_source/geom pour chaque table corrigee)
-- Puis relancer python scripts/03_export_gpkg.py pour regenerer les GPKG.

