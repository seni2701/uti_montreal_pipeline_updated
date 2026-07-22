-- 03b_nettoyage_debris_parterres.sql
-- Correctif CARTHAB (fichier suffixe) — NE MODIFIE PAS 03.
-- ---------------------------------------------------------------------------
-- Objet : retirer les parterres-debris (parts minuscules issues du ST_Split de
--         03) qui subsistent apres le departage. Coherent avec le seuil de
--         nettoyage des troncons (10 m2) applique en 02c.
--
-- Un vrai parterre (un cote d'un segment de rue) fait des dizaines a des
-- centaines de m2 ; en dessous de 10 m2 c'est un sliver de decoupage.
--
-- Placement : entre 03 et 04 (03_ < 03b_ < 04_). Rejouer couche_combinee apres.
-- Impact invariant : negligeable (< 12 000 m2 sur 100,7 M). SQL plat, runner only.
-- ===========================================================================

-- Comptage avant (lisible dans QGIS/psql si besoin) :
-- SELECT count(*) FROM uti.parterres
-- WHERE geom IS NULL OR ST_IsEmpty(geom) OR ST_Area(geom) < 10;

DELETE FROM uti.parterres
WHERE geom IS NULL
   OR ST_IsEmpty(geom)
   OR ST_Area(geom) < 10;
