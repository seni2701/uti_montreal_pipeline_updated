-- 02d_recuperation_troncons_absorbes.sql   (REVISION : departage interne + garde)
-- Correctif CARTHAB (fichier suffixe) — NE MODIFIE NI 02 NI 02b NI 02c.
-- ---------------------------------------------------------------------------
-- Objet : recuperer les troncons rendus VIDES par le departage 02c (segments
--         distincts, Q2=0), SANS recreer de chevauchement NI vider d'autres
--         troncons.
--
-- Corrections vs version precedente :
--   - Etape B (nouvelle) : les corridors recuperes sont departages ENTRE EUX
--     (priorite id inferieur) -> supprime le chevauchement corridor-corridor
--     (etait 188 paires / 14 250 m2).
--   - Etape D : GARDE anti-vidage -> la soustraction des corridors aux autres
--     troncons ne s'applique que si le resultat reste non vide (evite les 60
--     absorbeurs fins vides par la version precedente).
--
-- Placement : entre 02c et 03. Rejouer 03, 03b, ..., puis couche_combinee.
-- Non destructif. SQL plat, runner only.
-- ===========================================================================

-- ── Etape A : corridors de recuperation (troncons vides uniquement) ──────────
DROP TABLE IF EXISTS _reclaim;

CREATE TEMP TABLE _reclaim AS
SELECT t.id_trc,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(
           ST_Intersection(
               t.geom_avant_departage,
               ST_Buffer(t.axe, 7.0, 'endcap=flat join=round')
           )
       ), 3))::geometry(MultiPolygon, 2950) AS geom
FROM uti.troncons_polygones t
WHERE (t.geom IS NULL OR ST_IsEmpty(t.geom))
  AND t.geom_avant_departage IS NOT NULL AND NOT ST_IsEmpty(t.geom_avant_departage)
  AND t.axe IS NOT NULL AND NOT ST_IsEmpty(t.axe);

-- retire d'emblee les corridors vides (rien a recuperer)
DELETE FROM _reclaim WHERE geom IS NULL OR ST_IsEmpty(geom);

CREATE INDEX ON _reclaim USING GIST (geom);
ANALYZE _reclaim;

-- ── Etape B : departage des corridors ENTRE EUX (priorite id inferieur) ──────
WITH deover AS (
    SELECT r.id_trc,
           CASE WHEN u.g IS NULL THEN r.geom
                ELSE ST_Multi(ST_CollectionExtract(ST_MakeValid(
                        ST_Difference(r.geom, u.g)), 3))::geometry(MultiPolygon, 2950)
           END AS g
    FROM _reclaim r
    LEFT JOIN LATERAL (
        SELECT ST_Union(o.geom) AS g
        FROM _reclaim o
        WHERE o.id_trc < r.id_trc AND ST_Intersects(o.geom, r.geom)
    ) u ON true
)
UPDATE _reclaim r
SET geom = d.g
FROM deover d
WHERE r.id_trc = d.id_trc;

DELETE FROM _reclaim WHERE geom IS NULL OR ST_IsEmpty(geom);

-- ── Etape C : attribuer le corridor recupere aux troncons vides ─────────────
UPDATE uti.troncons_polygones t
SET geom = r.geom
FROM _reclaim r
WHERE t.id_trc = r.id_trc;

-- ── Etape D : soustraire les corridors aux AUTRES troncons, AVEC GARDE ───────
-- La soustraction n'est appliquee que si elle NE VIDE PAS le troncon (sinon il
-- conserve sa geometrie -> aucun troncon perdu). Le residuel eventuel est un
-- petit chevauchement absorbeur-corridor sur ces rares cas fins.
WITH strips AS (SELECT ST_Union(geom) AS g FROM _reclaim),
diff AS (
    SELECT t.id_trc,
           ST_Multi(ST_CollectionExtract(ST_MakeValid(
               ST_Difference(t.geom, s.g)), 3))::geometry(MultiPolygon, 2950) AS g
    FROM uti.troncons_polygones t
    CROSS JOIN strips s
    WHERE t.geom IS NOT NULL AND NOT ST_IsEmpty(t.geom)
      AND t.id_trc NOT IN (SELECT id_trc FROM _reclaim)
      AND ST_Intersects(t.geom, s.g)
)
UPDATE uti.troncons_polygones t
SET geom = diff.g
FROM diff
WHERE t.id_trc = diff.id_trc
  AND diff.g IS NOT NULL AND NOT ST_IsEmpty(diff.g);   -- GARDE : ne vide personne

DROP TABLE IF EXISTS _reclaim;

-- ── CONTROLES (psql) ────────────────────────────────────────────────────────
-- Vides restants  -> attendu ~0 :
--   SELECT count(*) FROM uti.troncons_polygones WHERE geom IS NULL OR ST_IsEmpty(geom);
-- Chevauchement   -> attendu tres faible (residuel absorbeur-corridor garde) :
--   [requete A1 des troncons]