-- 13d_create_rues_limites_utg.sql
-- Correctif CARTHAB (fichier suffixe) — NE MODIFIE NI 02 NI 14a.
-- ---------------------------------------------------------------------------
-- Objet : recreer uti.rues_limites_utg (sans prefixe), dependance de
--         14a_diagnostic_invalidites.sql.
--
-- Cause : 02 fait DROP ... CASCADE sur troncons_polygones (ce qui supprime les
--         vues dependantes) puis recree la vue sous le nom uti.v_rues_limites_utg
--         (avec prefixe v_). 14a interroge uti.rues_limites_utg (sans v_), objet
--         que plus aucun script ne cree apres une reconstruction propre depuis 02.
--
-- Solution : alias non filtrant sur la vue existante, memes colonnes. DRY : si
--         v_rues_limites_utg evolue, l'alias suit automatiquement.
--
-- Placement : entre 13c et 14a (13c_ < 13d_ < 14a_). Rejouable (CREATE OR
-- REPLACE), non destructif. SQL plat, runner uniquement.
-- ===========================================================================

CREATE OR REPLACE VIEW uti.rues_limites_utg AS
SELECT * FROM uti.v_rues_limites_utg;
