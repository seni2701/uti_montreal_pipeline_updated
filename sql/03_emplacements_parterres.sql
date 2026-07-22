-- 03_emplacements_parterres.sql
-- Livrable A — étape 3 : parterres pair/impair + terre-plein
-- Correction : ST_SetSRID sur la ligne de coupe pour éviter l'erreur SRID mixte.
-- Parité : gauche = impair, droite = pair (convention MTL).

DROP TABLE IF EXISTS uti.troncons_demis CASCADE;

CREATE TABLE uti.troncons_demis AS
WITH lame AS (
    SELECT
        id_trc,
        geom AS poly,
        axe,
        ST_StartPoint(axe) AS p0,
        ST_EndPoint(axe)   AS p1,
        ST_X(ST_EndPoint(axe)) - ST_X(ST_StartPoint(axe)) AS dx,
        ST_Y(ST_EndPoint(axe)) - ST_Y(ST_StartPoint(axe)) AS dy
    FROM uti.troncons_polygones
    WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
      AND axe  IS NOT NULL AND NOT ST_IsEmpty(axe)
      AND ST_Length(axe) > 0
),
axe_etendu AS (
    SELECT
        id_trc, poly, axe,
        -- CORRECTION : ST_SetSRID force le même SRID que le polygone (2950)
        ST_SetSRID(
            ST_MakeLine(
                ST_MakePoint(
                    ST_X(p0) - dx / NULLIF(sqrt(dx*dx + dy*dy), 0) * 10,
                    ST_Y(p0) - dy / NULLIF(sqrt(dx*dx + dy*dy), 0) * 10
                ),
                ST_MakePoint(
                    ST_X(p1) + dx / NULLIF(sqrt(dx*dx + dy*dy), 0) * 10,
                    ST_Y(p1) + dy / NULLIF(sqrt(dx*dx + dy*dy), 0) * 10
                )
            ),
        2950) AS coupe
    FROM lame
    -- Exclure les tronçons sans direction calculable
    WHERE dx IS NOT NULL AND dy IS NOT NULL
      AND (dx * dx + dy * dy) > 0
)
SELECT
    a.id_trc,
    row_number() OVER (PARTITION BY a.id_trc) AS demi_id,
    a.axe,
    (ST_Dump(ST_Split(a.poly, a.coupe))).geom AS geom,
    sign(
        (ST_X(ST_EndPoint(a.axe)) - ST_X(ST_StartPoint(a.axe)))
        * (ST_Y(ST_Centroid((ST_Dump(ST_Split(a.poly, a.coupe))).geom)) - ST_Y(ST_StartPoint(a.axe)))
        -
        (ST_Y(ST_EndPoint(a.axe)) - ST_Y(ST_StartPoint(a.axe)))
        * (ST_X(ST_Centroid((ST_Dump(ST_Split(a.poly, a.coupe))).geom)) - ST_X(ST_StartPoint(a.axe)))
    ) AS cote_signe
FROM axe_etendu a;

CREATE INDEX idx_troncons_demis_geom ON uti.troncons_demis USING GIST (geom);

-- ── Table parterres ────────────────────────────────────────────────────────
DROP TABLE IF EXISTS uti.parterres CASCADE;

CREATE TABLE uti.parterres AS
SELECT
    d.id_trc,
    d.demi_id,
    d.geom,
    CASE
        WHEN d.cote_signe > 0 THEN 'impair'
        WHEN d.cote_signe < 0 THEN 'pair'
        ELSE 'indetermine'
    END AS cote,
    FALSE AS terre_plein
FROM uti.troncons_demis d
WHERE d.geom IS NOT NULL AND NOT ST_IsEmpty(d.geom);

CREATE INDEX idx_parterres_geom  ON uti.parterres USING GIST (geom);
CREATE INDEX idx_parterres_tronc ON uti.parterres (id_trc);

-- Contrôle : SELECT cote, count(*) FROM uti.parterres GROUP BY cote;