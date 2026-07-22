-- ============================================================================
-- 21_segmentation_troncons_electriques.sql
-- SEGMENTATION DES LIGNES ÉLECTRIQUES ENTRE PYLÔNES CONSÉCUTIFS
-- ----------------------------------------------------------------------------
-- Règles :
--   • les pylônes sont projetés sur la partie de ligne la plus proche;
--   • les extrémités de chaque ligne sont ajoutées comme bornes virtuelles;
--   • 0 pylône  -> 1 tronçon correspondant à la ligne complète;
--   • 1 pylône  -> 2 tronçons;
--   • n pylônes -> jusqu'à n + 1 tronçons;
--   • les points de rupture séparés de moins de 1 cm sont dédoublonnés;
--   • les 5 pylônes légèrement décalés sont projetés sur leur ligne actuelle.
-- ============================================================================

DROP VIEW IF EXISTS uti.v_t2h_elec_troncons_anomalies CASCADE;
DROP VIEW IF EXISTS uti.v_t2h_elec_troncons_controle CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_troncons CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_pylones_projection CASCADE;

-- ============================================================================
-- 1 — PROJECTION DE CHAQUE PYLÔNE SUR SA LIGNE
-- ============================================================================

CREATE TABLE uti.t2h_elec_pylones_projection AS
WITH parties_lignes AS (
    SELECT
        l.id_ligne,
        ROW_NUMBER() OVER (
            PARTITION BY l.id_ligne
            ORDER BY d.path
        )::integer AS no_partie,
        d.geom::geometry(LineString, 2950) AS geom_ligne
    FROM uti.t2h_elec_lignes l
    CROSS JOIN LATERAL ST_Dump(
        ST_LineMerge(
            ST_CollectionExtract(
                ST_MakeValid(l.geom_sol),
                2
            )
        )
    ) d
    WHERE l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
      AND GeometryType(d.geom) = 'LINESTRING'
      AND ST_Length(d.geom) > 0.01
),
projection AS (
    SELECT
        p.id_pylone,
        p.id_ligne,
        x.no_partie,
        x.geom_ligne,
        ST_PointOnSurface(p.geom_polygone) AS geom_centre_pylone,
        ST_ClosestPoint(
            x.geom_ligne,
            ST_PointOnSurface(p.geom_polygone)
        )::geometry(Point, 2950) AS geom_projection
    FROM uti.t2h_elec_pylones p
    CROSS JOIN LATERAL (
        SELECT
            pl.no_partie,
            pl.geom_ligne
        FROM parties_lignes pl
        WHERE pl.id_ligne = p.id_ligne
        ORDER BY
            ST_Distance(
                ST_PointOnSurface(p.geom_polygone),
                pl.geom_ligne
            ),
            pl.no_partie
        LIMIT 1
    ) x
    WHERE p.geom_polygone IS NOT NULL
      AND NOT ST_IsEmpty(p.geom_polygone)
)
SELECT
    id_pylone,
    id_ligne,
    no_partie,
    ROUND(
        (
            ST_LineLocatePoint(
                geom_ligne,
                geom_projection
            )
            * ST_Length(geom_ligne)
        )::numeric,
        2
    ) AS chainage_m,
    ST_LineLocatePoint(
        geom_ligne,
        geom_projection
    ) AS position_normalisee,
    ROUND(
        ST_Distance(
            geom_centre_pylone,
            geom_ligne
        )::numeric,
        2
    ) AS distance_axe_m,
    geom_projection AS geom
FROM projection;

ALTER TABLE uti.t2h_elec_pylones_projection
    ADD CONSTRAINT t2h_elec_pylones_projection_pk
    PRIMARY KEY (id_pylone);

CREATE INDEX idx_t2h_elec_pylones_projection_ligne
    ON uti.t2h_elec_pylones_projection (id_ligne, no_partie);

CREATE INDEX idx_t2h_elec_pylones_projection_geom
    ON uti.t2h_elec_pylones_projection
    USING gist (geom);

-- ============================================================================
-- 2 — CRÉATION DES TRONÇONS
-- ============================================================================

CREATE TABLE uti.t2h_elec_troncons AS
WITH parties_lignes AS (
    SELECT
        l.id_ligne,
        l.reseau,
        l.tension_kv,
        ROW_NUMBER() OVER (
            PARTITION BY l.id_ligne
            ORDER BY d.path
        )::integer AS no_partie,
        d.geom::geometry(LineString, 2950) AS geom_ligne,
        ST_Length(d.geom) AS longueur_partie_m
    FROM uti.t2h_elec_lignes l
    CROSS JOIN LATERAL ST_Dump(
        ST_LineMerge(
            ST_CollectionExtract(
                ST_MakeValid(l.geom_sol),
                2
            )
        )
    ) d
    WHERE l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
      AND GeometryType(d.geom) = 'LINESTRING'
      AND ST_Length(d.geom) > 0.01
),
ruptures_brutes AS (
    SELECT
        pl.id_ligne,
        pl.no_partie,
        0.00::numeric AS chainage_m,
        NULL::integer AS id_pylone
    FROM parties_lignes pl

    UNION ALL

    SELECT
        p.id_ligne,
        p.no_partie,
        p.chainage_m,
        p.id_pylone
    FROM uti.t2h_elec_pylones_projection p

    UNION ALL

    SELECT
        pl.id_ligne,
        pl.no_partie,
        ROUND(pl.longueur_partie_m::numeric, 2) AS chainage_m,
        NULL::integer AS id_pylone
    FROM parties_lignes pl
),
ruptures_uniques AS (
    SELECT
        id_ligne,
        no_partie,
        chainage_m,
        MIN(id_pylone)
            FILTER (WHERE id_pylone IS NOT NULL)
            AS id_pylone,
        string_agg(
            id_pylone::text,
            ','
            ORDER BY id_pylone
        ) FILTER (WHERE id_pylone IS NOT NULL)
            AS ids_pylones
    FROM ruptures_brutes
    GROUP BY
        id_ligne,
        no_partie,
        chainage_m
),
intervalles AS (
    SELECT
        r.id_ligne,
        r.no_partie,
        r.chainage_m AS chainage_debut_m,
        LEAD(r.chainage_m) OVER (
            PARTITION BY r.id_ligne, r.no_partie
            ORDER BY r.chainage_m
        ) AS chainage_fin_m,
        r.id_pylone AS id_pylone_debut,
        LEAD(r.id_pylone) OVER (
            PARTITION BY r.id_ligne, r.no_partie
            ORDER BY r.chainage_m
        ) AS id_pylone_fin,
        r.ids_pylones AS ids_pylones_debut,
        LEAD(r.ids_pylones) OVER (
            PARTITION BY r.id_ligne, r.no_partie
            ORDER BY r.chainage_m
        ) AS ids_pylones_fin
    FROM ruptures_uniques r
),
segments_bruts AS (
    SELECT
        i.id_ligne,
        i.no_partie,
        pl.reseau,
        pl.tension_kv,
        i.chainage_debut_m,
        i.chainage_fin_m,
        i.id_pylone_debut,
        i.id_pylone_fin,
        i.ids_pylones_debut,
        i.ids_pylones_fin,
        ST_LineSubstring(
            pl.geom_ligne,
            GREATEST(
                0.0,
                LEAST(
                    1.0,
                    i.chainage_debut_m::double precision
                    / NULLIF(pl.longueur_partie_m, 0)
                )
            ),
            GREATEST(
                0.0,
                LEAST(
                    1.0,
                    i.chainage_fin_m::double precision
                    / NULLIF(pl.longueur_partie_m, 0)
                )
            )
        )::geometry(LineString, 2950) AS geom
    FROM intervalles i
    JOIN parties_lignes pl
      ON pl.id_ligne = i.id_ligne
     AND pl.no_partie = i.no_partie
    WHERE i.chainage_fin_m IS NOT NULL
      AND i.chainage_fin_m - i.chainage_debut_m > 0.01
),
segments_classes AS (
    SELECT
        *,
        CASE
            WHEN id_pylone_debut IS NULL
             AND id_pylone_fin IS NULL
                THEN 'LIGNE_COMPLETE'
            WHEN id_pylone_debut IS NULL
             AND id_pylone_fin IS NOT NULL
                THEN 'EXTREMITE_VERS_PYLONE'
            WHEN id_pylone_debut IS NOT NULL
             AND id_pylone_fin IS NOT NULL
                THEN 'ENTRE_PYLONES'
            WHEN id_pylone_debut IS NOT NULL
             AND id_pylone_fin IS NULL
                THEN 'PYLONE_VERS_EXTREMITE'
            ELSE 'NON_CLASSE'
        END::text AS type_troncon
    FROM segments_bruts
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_Length(geom) > 0.01
),
segments_ordonnes AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY id_ligne
            ORDER BY no_partie, chainage_debut_m
        )::integer AS ordre_troncon
    FROM segments_classes
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY id_ligne, no_partie, chainage_debut_m
    )::bigint AS id,
    'TR-ELEC-'
    || LPAD(id_ligne::text, 4, '0')
    || '-'
    || LPAD(
        ROW_NUMBER() OVER (
            PARTITION BY id_ligne
            ORDER BY no_partie, chainage_debut_m
        )::text,
        4,
        '0'
    ) AS id_troncon,
    id_ligne,
    no_partie,
    ordre_troncon,
    id_pylone_debut,
    id_pylone_fin,
    ids_pylones_debut,
    ids_pylones_fin,
    type_troncon,
    reseau,
    tension_kv,
    ROUND(chainage_debut_m::numeric, 2)
        AS chainage_debut_m,
    ROUND(chainage_fin_m::numeric, 2)
        AS chainage_fin_m,
    ROUND(ST_Length(geom)::numeric, 2)
        AS longueur_m,
    geom
FROM segments_ordonnes;

ALTER TABLE uti.t2h_elec_troncons
    ADD CONSTRAINT t2h_elec_troncons_pk
    PRIMARY KEY (id);

CREATE UNIQUE INDEX idx_t2h_elec_troncons_code
    ON uti.t2h_elec_troncons (id_troncon);

CREATE INDEX idx_t2h_elec_troncons_ligne
    ON uti.t2h_elec_troncons (id_ligne, ordre_troncon);

CREATE INDEX idx_t2h_elec_troncons_pylones
    ON uti.t2h_elec_troncons (
        id_pylone_debut,
        id_pylone_fin
    );

CREATE INDEX idx_t2h_elec_troncons_geom
    ON uti.t2h_elec_troncons
    USING gist (geom);

-- ============================================================================
-- 3 — CONTRÔLE DES LONGUEURS ET DES GÉOMÉTRIES
-- ============================================================================

CREATE VIEW uti.v_t2h_elec_troncons_anomalies AS
WITH longueurs_sources AS (
    SELECT
        l.id_ligne,
        ROUND(
            SUM(ST_Length(d.geom))::numeric,
            2
        ) AS longueur_source_m
    FROM uti.t2h_elec_lignes l
    CROSS JOIN LATERAL ST_Dump(
        ST_LineMerge(
            ST_CollectionExtract(
                ST_MakeValid(l.geom_sol),
                2
            )
        )
    ) d
    WHERE l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
      AND GeometryType(d.geom) = 'LINESTRING'
    GROUP BY l.id_ligne
),
longueurs_troncons AS (
    SELECT
        id_ligne,
        COUNT(*) AS nb_troncons,
        ROUND(SUM(ST_Length(geom))::numeric, 2)
            AS longueur_troncons_m,
        COUNT(*) FILTER (
            WHERE NOT ST_IsValid(geom)
               OR ST_IsEmpty(geom)
               OR ST_Length(geom) <= 0.01
        ) AS nb_geometries_invalides
    FROM uti.t2h_elec_troncons
    GROUP BY id_ligne
)
SELECT
    s.id_ligne,
    s.longueur_source_m,
    COALESCE(t.longueur_troncons_m, 0)
        AS longueur_troncons_m,
    ROUND(
        ABS(
            s.longueur_source_m
            - COALESCE(t.longueur_troncons_m, 0)
        )::numeric,
        2
    ) AS ecart_longueur_m,
    COALESCE(t.nb_troncons, 0) AS nb_troncons,
    COALESCE(t.nb_geometries_invalides, 0)
        AS nb_geometries_invalides
FROM longueurs_sources s
LEFT JOIN longueurs_troncons t
  ON t.id_ligne = s.id_ligne
WHERE ABS(
    s.longueur_source_m
    - COALESCE(t.longueur_troncons_m, 0)
) > 0.10
   OR COALESCE(t.nb_geometries_invalides, 0) > 0
   OR COALESCE(t.nb_troncons, 0) = 0;

CREATE VIEW uti.v_t2h_elec_troncons_controle AS
SELECT
    COUNT(*) AS nb_troncons,
    COUNT(DISTINCT id_ligne) AS nb_lignes_segmentees,
    COUNT(*) FILTER (
        WHERE type_troncon = 'ENTRE_PYLONES'
    ) AS nb_entre_pylones,
    COUNT(*) FILTER (
        WHERE type_troncon = 'EXTREMITE_VERS_PYLONE'
    ) AS nb_extremite_vers_pylone,
    COUNT(*) FILTER (
        WHERE type_troncon = 'PYLONE_VERS_EXTREMITE'
    ) AS nb_pylone_vers_extremite,
    COUNT(*) FILTER (
        WHERE type_troncon = 'LIGNE_COMPLETE'
    ) AS nb_lignes_sans_pylone,
    ROUND(SUM(longueur_m)::numeric, 2)
        AS longueur_totale_m
FROM uti.t2h_elec_troncons;

-- ============================================================================
-- 4 — CONTRÔLE BLOQUANT
-- ============================================================================

DO $controle_segmentation$
DECLARE
    n_lignes_source integer;
    n_lignes_segmentees integer;
    n_anomalies integer;
    n_troncons integer;
BEGIN
    SELECT COUNT(*)
    INTO n_lignes_source
    FROM uti.t2h_elec_lignes
    WHERE geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(geom_sol);

    SELECT
        COUNT(DISTINCT id_ligne),
        COUNT(*)
    INTO n_lignes_segmentees, n_troncons
    FROM uti.t2h_elec_troncons;

    SELECT COUNT(*)
    INTO n_anomalies
    FROM uti.v_t2h_elec_troncons_anomalies;

    IF n_lignes_segmentees <> n_lignes_source THEN
        RAISE EXCEPTION
            'Segmentation incomplète : % lignes sources, % lignes segmentées.',
            n_lignes_source,
            n_lignes_segmentees;
    END IF;

    IF n_anomalies > 0 THEN
        RAISE EXCEPTION
            '% ligne(s) présentent une anomalie de longueur ou de géométrie.',
            n_anomalies;
    END IF;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'SEGMENTATION DES LIGNES ÉLECTRIQUES';
    RAISE NOTICE '  lignes sources    : %', n_lignes_source;
    RAISE NOTICE '  lignes segmentées : %', n_lignes_segmentees;
    RAISE NOTICE '  tronçons créés    : %', n_troncons;
    RAISE NOTICE '  anomalies         : %', n_anomalies;
    RAISE NOTICE '--------------------------------------------------';
END
$controle_segmentation$;
