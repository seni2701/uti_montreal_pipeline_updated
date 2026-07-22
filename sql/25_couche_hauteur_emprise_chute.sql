-- ============================================================================
-- 25_couche_hauteur_emprise_chute.sql
-- COUCHE DÉDIÉE : HAUTEUR DES PYLÔNES + EMPRISE DE CHUTE
-- ----------------------------------------------------------------------------
-- Géométrie active :
--   geom = polygone d'emprise de chute
--
-- Mesures principales :
--   hauteur_pylone_m
--   rayon_chute_m
--   surface_chute_m2
--
-- Important :
--   les entités restent sans géométrie tant que hauteur_pylone_m est NULL.
-- ============================================================================

DROP VIEW IF EXISTS uti.v_t2h_elec_lignes_chute CASCADE;
DROP VIEW IF EXISTS uti.v_t2h_elec_pylones_chute_controle CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_pylones_chute CASCADE;


CREATE TABLE uti.t2h_elec_pylones_chute AS
SELECT
    p.id_pylone,
    p.id_ligne,

    p.hauteur_pylone_m,
    p.altitude_sol_m,
    p.altitude_sommet_m,

    COALESCE(p.marge_chute_m, 2)::numeric
        AS marge_chute_m,

    CASE
        WHEN p.hauteur_pylone_m IS NOT NULL
         AND p.hauteur_pylone_m > 0
        THEN ROUND(
            (
                p.hauteur_pylone_m
                + COALESCE(p.marge_chute_m, 2)
            )::numeric,
            2
        )
        ELSE NULL
    END AS rayon_chute_m,

    CASE
        WHEN p.hauteur_pylone_m IS NOT NULL
         AND p.hauteur_pylone_m > 0
        THEN ROUND(
            ST_Area(
                ST_Buffer(
                    ST_PointOnSurface(p.geom_polygone),
                    p.hauteur_pylone_m
                    + COALESCE(p.marge_chute_m, 2)
                )
            )::numeric,
            2
        )
        ELSE NULL
    END AS surface_chute_m2,

    p.source_hauteur,
    p.methode_hauteur,
    p.annee_lidar,
    p.qualite_hauteur,

    ST_AsText(
        ST_PointOnSurface(p.geom_polygone)
    ) AS centre_pylone_wkt,

    CASE
        WHEN p.hauteur_pylone_m IS NOT NULL
         AND p.hauteur_pylone_m > 0
        THEN ST_Multi(
            ST_Buffer(
                ST_PointOnSurface(p.geom_polygone),
                p.hauteur_pylone_m
                + COALESCE(p.marge_chute_m, 2)
            )
        )::geometry(MultiPolygon, 2950)
        ELSE NULL::geometry(MultiPolygon, 2950)
    END AS geom

FROM uti.t2h_elec_pylones p;


ALTER TABLE uti.t2h_elec_pylones_chute
    ADD CONSTRAINT t2h_elec_pylones_chute_pk
    PRIMARY KEY (id_pylone);

CREATE INDEX idx_t2h_elec_pylones_chute_ligne
    ON uti.t2h_elec_pylones_chute (id_ligne);

CREATE INDEX idx_t2h_elec_pylones_chute_geom
    ON uti.t2h_elec_pylones_chute
    USING gist (geom);


CREATE VIEW uti.v_t2h_elec_lignes_chute AS
SELECT
    id_ligne,
    COUNT(*) AS nb_pylones,

    COUNT(*) FILTER (
        WHERE hauteur_pylone_m IS NOT NULL
    ) AS nb_avec_hauteur,

    ROUND(
        MAX(hauteur_pylone_m)::numeric,
        2
    ) AS hauteur_max_m,

    ROUND(
        AVG(hauteur_pylone_m)::numeric,
        2
    ) AS hauteur_moyenne_m,

    ROUND(
        ST_Area(
            ST_UnaryUnion(
                ST_Collect(geom)
            )
        )::numeric,
        2
    ) AS emprise_chute_ligne_m2,

    ST_Multi(
        ST_CollectionExtract(
            ST_UnaryUnion(
                ST_Collect(geom)
            ),
            3
        )
    )::geometry(MultiPolygon, 2950) AS geom

FROM uti.t2h_elec_pylones_chute
WHERE geom IS NOT NULL
GROUP BY id_ligne;


CREATE VIEW uti.v_t2h_elec_pylones_chute_controle AS
SELECT
    COUNT(*) AS nb_pylones,
    COUNT(*) FILTER (
        WHERE hauteur_pylone_m IS NOT NULL
    ) AS nb_avec_hauteur,
    COUNT(*) FILTER (
        WHERE geom IS NOT NULL
    ) AS nb_avec_emprise_chute,
    COUNT(*) FILTER (
        WHERE hauteur_pylone_m IS NULL
    ) AS nb_sans_hauteur
FROM uti.t2h_elec_pylones_chute;


DO $controle_chute$
DECLARE
    r record;
BEGIN
    SELECT *
    INTO r
    FROM uti.v_t2h_elec_pylones_chute_controle;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'COUCHE HAUTEUR + EMPRISE DE CHUTE';
    RAISE NOTICE '  pylônes             : %', r.nb_pylones;
    RAISE NOTICE '  avec hauteur        : %', r.nb_avec_hauteur;
    RAISE NOTICE '  avec emprise chute  : %', r.nb_avec_emprise_chute;
    RAISE NOTICE '  sans hauteur        : %', r.nb_sans_hauteur;
    RAISE NOTICE '--------------------------------------------------';
END
$controle_chute$;
