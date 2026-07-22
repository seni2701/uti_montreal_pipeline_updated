-- 02b_fix_emprise_troncons.sql   (REVISION : emprise cadastrale par soustraction)
-- Correctif CARTHAB (fichier suffixe) — NE MODIFIE NI 02 NI 03.
-- ---------------------------------------------------------------------------
-- Objet : confiner uti.troncons_polygones a l'EMPRISE PUBLIQUE de la rue =
--         tampon d'origine (01/02) MOINS les lots prives du cadastre, puis
--         NETTOYAGE des debris (parts polygonales trop petites). Uniforme.
--
-- Methode :
--   - On repart de geom_avant_clip (le tampon d'origine preserve) : le calcul
--     est independant de toute tentative de clip anterieure et rejouable.
--   - On soustrait les lots du cadastre qui touchent le troncon MAIS ne
--     traversent PAS l'axe. Un lot prive riverain ne croise pas l'axe ; un
--     eventuel parcellaire de rue le contient -> ainsi la rue n'est jamais
--     retiree, seules les parcelles riveraines le sont.
--   - Nettoyage : on eclate le resultat, on retire les parts < MIN_PART_M2,
--     on recombine. Elimine les debris de facon uniforme.
--
-- Chaine : entre 02 et 03. Rejouer 03 + 03b + 07 + couche_combinee ensuite.
-- Non destructif (geom_avant_clip conserve l'original). SQL plat, runner only.
-- ===========================================================================

-- >>> Parametre unique : aire minimale (m2) d'une part conservee (anti-debris).
--     Les slivers de clip font < 1 m2 ; un vrai parterre fait des dizaines de m2.
--     Augmenter si des debris subsistent, diminuer si de vraies parts sautent.
--     Valeur appliquee : 10 (litteral, plus bas — le runner ne gere pas :var).

-- ── Etape A : lots du cadastre pre-valides + indexes (patron _table_ref_valide)
-- Colonne geometrique de raw.cadastre = 'geometry'. Aucun filtre de colonne.
DROP TABLE IF EXISTS _lots_valides;

CREATE TEMP TABLE _lots_valides AS
SELECT CASE WHEN ST_IsValid(geometry) THEN geometry
            ELSE ST_CollectionExtract(ST_MakeValid(geometry), 3) END AS geom
FROM raw.cadastre
WHERE geometry IS NOT NULL;

CREATE INDEX ON _lots_valides USING GIST (geom);
ANALYZE _lots_valides;

-- ── Etape B : colonnes d'audit + sauvegarde de la geometrie d'origine ────────
ALTER TABLE uti.troncons_polygones
    ADD COLUMN IF NOT EXISTS geom_avant_clip  geometry(MultiPolygon, 2950),
    ADD COLUMN IF NOT EXISTS surface_avant_m2 double precision,
    ADD COLUMN IF NOT EXISTS surface_apres_m2 double precision,
    ADD COLUMN IF NOT EXISTS pct_debord       double precision;

-- Copie l'original (tampon 01/02) une seule fois. Sur reprise depuis 02, la
-- table est recreee a neuf : geom_avant_clip repart donc du tampon. Sur simple
-- relance de 02b, geom_avant_clip existe deja -> l'original est preserve.
UPDATE uti.troncons_polygones
SET geom_avant_clip = geom
WHERE geom_avant_clip IS NULL;

-- ── Etape C : corridor = tampon d'origine MOINS lots prives, puis nettoyage ──
WITH lots_troncon AS (
    -- Union des lots RIVERAINS (touchent le troncon, ne croisent pas son axe).
    SELECT t.id_trc,
           ST_Union(l.geom) AS lots
    FROM uti.troncons_polygones t
    JOIN _lots_valides l
      ON ST_Intersects(l.geom, t.geom_avant_clip)
     AND NOT ST_Intersects(l.geom, t.axe)
    GROUP BY t.id_trc
),
corridor AS (
    -- Soustraction des lots ; si aucun lot riverain, on garde le tampon.
    SELECT t.id_trc,
           CASE WHEN lt.lots IS NULL THEN t.geom_avant_clip
                ELSE ST_Difference(t.geom_avant_clip, lt.lots) END AS g
    FROM uti.troncons_polygones t
    LEFT JOIN lots_troncon lt ON lt.id_trc = t.id_trc
),
nettoye AS (
    -- Eclatement -> on ne garde que les parts >= 10 m2 -> recombinaison.
    SELECT c.id_trc,
           ST_Multi(ST_CollectionExtract(ST_Union(d.geom), 3)
           )::geometry(MultiPolygon, 2950) AS g
    FROM corridor c
    CROSS JOIN LATERAL ST_Dump(ST_CollectionExtract(ST_MakeValid(c.g), 3)) AS d
    WHERE ST_Area(d.geom) >= 10          -- MIN_PART_M2 (anti-debris)
    GROUP BY c.id_trc
)
UPDATE uti.troncons_polygones t
SET geom = n.g
FROM nettoye n
WHERE t.id_trc = n.id_trc
  AND n.g IS NOT NULL
  AND NOT ST_IsEmpty(n.g);

-- ── Etape D : audit ─────────────────────────────────────────────────────────
UPDATE uti.troncons_polygones
SET surface_avant_m2 = ST_Area(geom_avant_clip),
    surface_apres_m2 = ST_Area(geom),
    pct_debord = CASE WHEN ST_Area(geom_avant_clip) > 0
        THEN 100.0 * (ST_Area(geom_avant_clip) - ST_Area(geom))
             / ST_Area(geom_avant_clip)
        ELSE 0 END;

-- ── CONTROLES (lire dans QGIS : le runner n'affiche pas les SELECT) ──────────
-- CONTROLE 1 : reduction globale. Doit etre nettement positive (le tampon est
-- rabote a l'emprise publique). Statistiques QGIS sur pct_debord.
SELECT ROUND(SUM(surface_avant_m2)::numeric, 0) AS aire_avant_m2,
       ROUND(SUM(surface_apres_m2)::numeric, 0) AS aire_apres_m2,
       ROUND((100.0 * (SUM(surface_avant_m2) - SUM(surface_apres_m2))
              / NULLIF(SUM(surface_avant_m2), 0))::numeric, 1) AS pct_reduction_global
FROM uti.troncons_polygones;

-- CONTROLE 2 : troncons vides (a eviter : 03 les perd). Si > 0, la soustraction
-- a tout retire -> lots trop englobants sur ces axes, a inspecter.
SELECT count(*) AS troncons_vides
FROM uti.troncons_polygones
WHERE geom IS NULL OR ST_IsEmpty(geom);

-- CONTROLE 3 : troncons inchanges (aucune reduction) -> pas de lot riverain
-- detecte sur ces axes.
SELECT count(*) AS troncons_non_reduits
FROM uti.troncons_polygones
WHERE pct_debord < 0.01;

DROP TABLE IF EXISTS _lots_valides;