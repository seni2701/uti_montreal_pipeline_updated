-- =====================================================================
-- 14c_bis_fix_srid_parterres.sql
-- Corrige la CONTRAINTE DE TYPE de uti.parterres.geom : geometry(Geometry,0)
-- -> geometry(MultiPolygon,2950). L'ALTER etant bloque par la vue dependante
-- v_relations_actives, on detache la vue, on altere, on recree la vue
-- A L'IDENTIQUE (definition recuperee via pg_get_viewdef).
--
-- Rappel : les DONNEES sont deja en 2950 (14c a fait l'UPDATE ST_SetSRID) ;
-- les relations spatiales parterre<->lots fonctionnent deja. Ce script ne
-- corrige que l'exactitude du catalogue geometry_columns.
--
-- CORRECTIF : la cible etait Polygon (type confirme au moment de l'ecriture
-- initiale : POLYGON, 99962/99962). Depuis, 05d_fix_debris_parterres.sql
-- (qui s'execute avant 14c_bis dans l'ordre du runner) reconstruit
-- uti.parterres.geom en ST_Multi(...)::geometry(MultiPolygon, 2950). La
-- cible de ce script doit donc suivre : MultiPolygon, pas Polygon. Le
-- USING applique ST_Multi() en plus de ST_SetSRID() pour rester robuste
-- meme si une ligne isolee etait encore un simple Polygon.
--
-- Convention CARTHAB : fichier suffixe, aucun script numerote modifie.
-- Runner SQLAlchemy : une instruction par ligne (pas de bloc DO).
-- =====================================================================

-- 1) Detacher la vue qui verrouille la colonne
DROP VIEW IF EXISTS uti.v_relations_actives;

-- 2) Fixer le type + SRID de la colonne (ST_SetSRID relabellise, ne transforme rien ;
--    ST_Multi garantit un MultiPolygon meme si une geometrie isolee est un Polygon simple)
ALTER TABLE uti.parterres
  ALTER COLUMN geom TYPE geometry(MultiPolygon, 2950)
  USING ST_Multi(ST_SetSRID(geom, 2950));

-- 3) Recreer la vue A L'IDENTIQUE (definition d'origine, inchangee)
CREATE VIEW uti.v_relations_actives AS
 SELECT tl.id_treevans,
    tl.id_trc,
    tl.cote,
    tl.no_lot,
    tl.arrondissement_lot,
    tl.surface_lot_m2,
    tl.type_relation,
    tl.date_activation,
    p.geom AS geom_parterre,
    tl.geom_lot
   FROM uti.troncons_lots tl
     JOIN uti.parterres p ON p.id_treevans = tl.id_treevans
  WHERE tl.actif = true;

-- 4) Rafraichir le catalogue
SELECT Populate_Geometry_Columns('uti.parterres'::regclass);

-- Controle : relancer  python scripts\diagnostic_uti.py
-- Le bloc [S] doit afficher parterres | geom | MULTIPOLYGON | 2950
-- et v_relations_actives | geom_parterre | ... | 2950