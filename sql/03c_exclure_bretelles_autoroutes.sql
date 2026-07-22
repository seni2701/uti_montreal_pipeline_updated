-- 03c_exclure_bretelles_autoroutes.sql
-- Correctif CARTHAB (fichier suffixe) — NE MODIFIE NI 03 NI 07.
-- ---------------------------------------------------------------------------
-- Objet : exclure du livrable PARTERRES les troncons autoroutiers et de
--         bretelles (echangeurs) : chaussee pure, ni pair/impair, ni adresse,
--         ni lot -> hors priorite mandat. Les TERRE-PLEINS de ces troncons
--         (bandes vegetales, ilots) restent dans uti.terre_pleins.
-- TRACE : parterres retires copies dans uti.parterres_exclues_chaussee.
--
-- NB : 'classe' est un CODE NUMERIQUE (bigint) dans reseau_routier, pas un
--      libelle -> on filtre par liste de codes (pas ILIKE).
--
-- Placement : entre 03b et 04. Rejouer 04..13 + couche_combinee ensuite.
-- ===========================================================================

-- >>> A CONFIRMER : codes 'classe' des autoroutes / bretelles. <<<
--   Diagnostic (pgAdmin) :
--     SELECT classe, count(*),
--            count(*) FILTER (WHERE nom_rue ILIKE '%autoroute%'
--               OR nom_rue ILIKE '%transcanad%' OR nom_rue ILIKE '%felix-leclerc%')
--     FROM uti.troncons_polygones GROUP BY classe ORDER BY classe;
--   Reporter les codes reperes dans la liste CODES_CHAUSSEE ci-dessous.

-- ── Etape A : trace des parterres a exclure (audit, non destructif) ──────────
DROP TABLE IF EXISTS uti.parterres_exclues_chaussee;

CREATE TABLE uti.parterres_exclues_chaussee AS
SELECT p.*, t.classe AS classe_troncon
FROM uti.parterres p
JOIN uti.troncons_polygones t ON t.id_trc = p.id_trc
WHERE t.classe = ANY (ARRAY[10, 11, 12]);   -- <-- CODES_CHAUSSEE a confirmer

CREATE INDEX ON uti.parterres_exclues_chaussee USING GIST (geom);

-- ── Etape B : retrait des parterres de chaussee autoroutiere ────────────────
DELETE FROM uti.parterres p
USING uti.troncons_polygones t
WHERE t.id_trc = p.id_trc
  AND t.classe = ANY (ARRAY[10, 11, 12]);   -- <-- meme liste de codes

-- ── CONTROLES (pgAdmin) ─────────────────────────────────────────────────────
-- SELECT count(*) FROM uti.parterres_exclues_chaussee;          -- 0 => codes a ajuster
-- SELECT count(*) FROM uti.terre_pleins;                        -- inchange
-- SELECT classe_troncon, count(*) FROM uti.parterres_exclues_chaussee
--   GROUP BY 1 ORDER BY 2 DESC;