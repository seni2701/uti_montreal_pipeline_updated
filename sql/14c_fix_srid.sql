-- =====================================================================
-- 14c_fix_srid.sql   (v2 -- contourne la dependance de vue)
-- DECLARE le SRID 2950 sur les geometries laissees en SRID 0, SANS
-- alterer le type de colonne (UpdateGeometrySRID echoue car la vue
-- uti.v_relations_actives depend de uti.parterres.geom).
--
-- Methode : UPDATE ... SET geom = ST_SetSRID(geom, 2950).
--   ST_SetSRID relabellise chaque geometrie SANS deplacer une coordonnee
--   (les coords sont deja en MTM8, cf diagnostic_uti.py [S2]).
--   Un UPDATE ne declenche PAS d'ALTER COLUMN -> aucune collision avec la vue.
--
-- Convention CARTHAB : fichier suffixe, aucun script numerote modifie.
-- Runner SQLAlchemy : une instruction par ligne (pas de bloc DO).
--
-- Cibles (cf bloc [S] du diagnostic) :
--   uti.parterres.geom       GEOMETRY SRID 0 -> 2950   (EMPLACEMENT : critique)
--   uti.troncons_demis.geom  GEOMETRY SRID 0 -> 2950
-- La vue uti.v_relations_actives (geom_parterre) refletera le 2950 sans action.
-- =====================================================================

-- Declaration du SRID par relabellisation (aucune transformation de coordonnees)
UPDATE uti.troncons_demis SET geom = ST_SetSRID(geom, 2950) WHERE ST_SRID(geom) <> 2950;
UPDATE uti.parterres      SET geom = ST_SetSRID(geom, 2950) WHERE ST_SRID(geom) <> 2950;

-- Met a jour le catalogue geometry_columns pour refleter le nouveau SRID.
-- Populate_Geometry_Columns ne fait pas d'ALTER destructif sur les vues ;
-- il recalcule les metadonnees a partir des geometries reelles.
SELECT Populate_Geometry_Columns('uti.parterres'::regclass);
SELECT Populate_Geometry_Columns('uti.troncons_demis'::regclass);

-- Controle : relancer  python scripts\diagnostic_uti.py
-- Le bloc [S] doit desormais afficher SRID 2950 pour parterres et troncons_demis.