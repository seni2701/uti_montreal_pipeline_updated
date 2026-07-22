-- 02c_departage_troncons.sql
-- Correctif CARTHAB (fichier suffixe) — NE MODIFIE NI 02 NI 02b NI 03.
-- ---------------------------------------------------------------------------
-- Objet : transformer uti.troncons_polygones en PARTITION propre (tronçons
--         adjacents qui se touchent SANS se chevaucher). Supprime les
--         43 M m2 de recouvrement herite ensuite par les parterres.
--
-- Methode (Option A — departage par priorite, contre un SNAPSHOT) :
--   Chaque troncon cede a tout troncon d'id INFERIEUR la zone qu'ils partagent.
--   La difference se calcule contre l'etat AVANT departage (table _trc_snap),
--   ce qui garantit une partition COMPLETE et SANS chevauchement :
--     - pour toute paire a<b : b exclut la geom d'origine de a -> aucun
--       chevauchement residuel entre finals ;
--     - l'union des finals = l'union des originaux -> aucune lacune (chaque m2
--       va au plus petit id qui le couvrait).
--   Puis nettoyage des debris (parts polygonales < 10 m2).
--
-- Chaine : 02 -> 02b -> 02c -> 03 -> ... -> couche_combinee_uti.py (a rejouer).
-- Non destructif (geom_avant_departage conserve l'etat d'entree). SQL plat.
-- ===========================================================================

-- ── Etape A : snapshot indexe de l'etat d'entree (base des differences) ──────
DROP TABLE IF EXISTS _trc_snap;

CREATE TEMP TABLE _trc_snap AS
SELECT id_trc, geom
FROM uti.troncons_polygones
WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom);

CREATE INDEX ON _trc_snap USING GIST (geom);
ANALYZE _trc_snap;

-- ── Etape B : audit + sauvegarde de la geom d'entree ────────────────────────
ALTER TABLE uti.troncons_polygones
    ADD COLUMN IF NOT EXISTS geom_avant_departage geometry(MultiPolygon, 2950),
    ADD COLUMN IF NOT EXISTS surface_cedee_m2     double precision;

UPDATE uti.troncons_polygones
SET geom_avant_departage = geom
WHERE geom_avant_departage IS NULL;

-- ── Etape C : departage — chaque troncon MOINS l'union des id inferieurs ─────
WITH deover AS (
    SELECT t.id_trc,
           CASE
               WHEN u.g IS NULL THEN t.geom
               ELSE ST_Multi(ST_CollectionExtract(
                        ST_MakeValid(ST_Difference(t.geom, u.g)), 3
                    ))::geometry(MultiPolygon, 2950)
           END AS g
    FROM _trc_snap t
    LEFT JOIN LATERAL (
        SELECT ST_Union(o.geom) AS g
        FROM _trc_snap o
        WHERE o.id_trc < t.id_trc
          AND ST_Intersects(o.geom, t.geom)
    ) u ON true
)
UPDATE uti.troncons_polygones t
SET geom = d.g            -- peut devenir vide si le troncon est entierement
FROM deover d             -- absorbe par des voisins d'id inferieur (voir CONTROLE 2)
WHERE t.id_trc = d.id_trc;

-- ── Etape D : nettoyage des debris (parts < 10 m2) ──────────────────────────
WITH nettoye AS (
    SELECT t.id_trc,
           ST_Multi(ST_CollectionExtract(ST_Union(d.geom), 3)
           )::geometry(MultiPolygon, 2950) AS g
    FROM uti.troncons_polygones t
    CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(ST_MakeValid(t.geom), 3)) AS d
    WHERE t.geom IS NOT NULL AND NOT ST_IsEmpty(t.geom)
      AND ST_Area(d.geom) >= 10
    GROUP BY t.id_trc
)
UPDATE uti.troncons_polygones t
SET geom = n.g
FROM nettoye n
WHERE t.id_trc = n.id_trc;

-- ── Etape E : audit surface cedee ───────────────────────────────────────────
UPDATE uti.troncons_polygones
SET surface_cedee_m2 = ST_Area(geom_avant_departage) - COALESCE(ST_Area(geom), 0);

DROP TABLE IF EXISTS _trc_snap;

-- ===========================================================================
-- CONTROLES A LANCER DANS psql APRES coup (le runner n'affiche pas les SELECT)
-- ---------------------------------------------------------------------------
-- CONTROLE 1 — chevauchement residuel : doit tomber a ~0.
--   WITH p AS (
--     SELECT ST_Area(ST_Intersection(a.geom,b.geom)) s
--     FROM uti.troncons_polygones a JOIN uti.troncons_polygones b
--       ON a.id_trc < b.id_trc AND ST_Intersects(a.geom,b.geom)
--   )
--   SELECT count(*) FILTER (WHERE s>0.5) AS paires_residuelles,
--          ROUND(SUM(s) FILTER (WHERE s>0.5)::numeric,0) AS surface_residuelle_m2
--   FROM p;
--
-- CONTROLE 2 — troncons devenus vides (absorbes par des voisins) :
--   SELECT count(*) FROM uti.troncons_polygones WHERE geom IS NULL OR ST_IsEmpty(geom);
--   -> si eleve, ce sont des doublons geometriques a examiner (id_treevans perdu).
--
-- CONTROLE 3 — surface totale (vraie partition, plus basse que 183 232 624) :
--   SELECT ROUND(ST_Area(ST_Union(geom))::numeric,0) AS surface_union_m2,
--          ROUND(SUM(ST_Area(geom))::numeric,0)      AS somme_geoms_m2
--   FROM uti.troncons_polygones;
--   -> surface_union_m2 et somme_geoms_m2 doivent maintenant COINCIDER.
-- ===========================================================================