-- ============================================================================
-- 24_couche_maitresse_pair_impair_sans_coupures.sql
-- LIVRABLE D V11.3 — PAIR / IMPAIR SANS COUPURES + ZONAGE SPATIAL
-- ----------------------------------------------------------------------------
-- Une seule entité PAIR et une seule entité IMPAIR par ligne.
--
-- Colonnes rétablies :
--   id_troncon : liste de tous les identifiants de tronçons de la ligne
--   nb_lots    : nombre de lots distincts associés au côté
--
-- La géométrie reste non segmentée.
-- ============================================================================


DROP VIEW IF EXISTS uti.v_t2h_maitresse_pair_impair_controle CASCADE;
DROP TABLE IF EXISTS uti.couche_livrable_t2h_maitresse CASCADE;


CREATE INDEX IF NOT EXISTS idx_affectation_pum_geometry
    ON raw.affectation_pum
    USING gist (geometry);

ANALYZE raw.affectation_pum;


CREATE TABLE uti.couche_livrable_t2h_maitresse AS
WITH stats_troncons AS (
    SELECT
        id_ligne,

        COUNT(*) AS nb_troncons,

        ROUND(
            SUM(longueur_m)::numeric,
            2
        ) AS longueur_troncons_totale_m,

        STRING_AGG(
            id_troncon,
            ', '
            ORDER BY ordre_troncon
        ) AS id_troncon,

        MIN(id_troncon) AS premier_id_troncon,
        MAX(id_troncon) AS dernier_id_troncon

    FROM uti.t2h_elec_troncons
    GROUP BY id_ligne
),
zonage_par_emprise AS (
    -- Intersection spatiale sans découper la géométrie finale.
    -- Le zonage est calculé séparément pour PAIR et IMPAIR.
    SELECT
        f.id_ligne,
        f.emplacement,

        STRING_AGG(
            DISTINCT BTRIM(z.affectatio),
            ', '
            ORDER BY BTRIM(z.affectatio)
        ) FILTER (
            WHERE NULLIF(BTRIM(z.affectatio), '') IS NOT NULL
        ) AS zonage_affectation,

        COUNT(
            DISTINCT BTRIM(z.affectatio)
        ) FILTER (
            WHERE NULLIF(BTRIM(z.affectatio), '') IS NOT NULL
        )::integer AS nb_zonages

    FROM uti.couche_livrable_t2h_sol f
    LEFT JOIN raw.affectation_pum z
      ON z.geometry && f.geom
     AND ST_Intersects(
            ST_MakeValid(f.geom),
            ST_MakeValid(z.geometry)
         )
    GROUP BY
        f.id_ligne,
        f.emplacement
),
lignes AS (
    SELECT
        id_ligne,

        ST_AsText(
            ST_LineMerge(
                ST_CollectionExtract(
                    ST_MakeValid(geom_sol),
                    2
                )
            )
        ) AS geom_ligne_wkt

    FROM uti.t2h_elec_lignes
    WHERE geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(geom_sol)
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY f.id_ligne, f.emplacement
    )::bigint AS id,

    'LIGNE-'
    || LPAD(f.id_ligne::text, 4, '0')
    || '-'
    || CASE
        WHEN f.emplacement = 'PAIR' THEN 'P'
        ELSE 'I'
    END AS id_emprise,

    f.id_ligne,

    -- Tous les tronçons de la ligne dans une seule colonne textuelle.
    t.id_troncon,

    f.emplacement,

    f.reseau,
    f.exploitant,
    f.tension_kv,

    f.largeur_buffer_m,
    f.largeur_emprise_totale_m,
    f.longueur_ligne_sol_m,

    COALESCE(t.nb_troncons, 0) AS nb_troncons,
    t.longueur_troncons_totale_m,
    t.premier_id_troncon,
    t.dernier_id_troncon,

    f.numeros_lots,

    CASE
        WHEN f.numeros_lots IS NULL
          OR BTRIM(f.numeros_lots) = ''
          OR UPPER(f.numeros_lots) = 'HORS CADASTRE'
            THEN 0
        ELSE CARDINALITY(
            STRING_TO_ARRAY(
                f.numeros_lots,
                ', '
            )
        )
    END::integer AS nb_lots,

    f.regime_foncier,
    f.statut_cadastre,

    COALESCE(z.zonage_affectation, 'NON RENSEIGNE')
        AS zonage_affectation,

    COALESCE(z.nb_zonages, 0)
        AS nb_zonages,

    f.surface_m2,
    f.emprise_sol_m2,
    f.empreinte_ligne_sol_m2,

    f.hauteur_ligne_m,
    f.hauteur_vegetation_max_m,
    f.emprise_chute_m2,

    l.geom_ligne_wkt,

    'PAIR_IMPAIR_SANS_DECOUPAGE'::text
        AS methode_geometrie,

    f.geom

FROM uti.couche_livrable_t2h_sol f
LEFT JOIN stats_troncons t
  ON t.id_ligne = f.id_ligne
LEFT JOIN zonage_par_emprise z
  ON z.id_ligne = f.id_ligne
 AND z.emplacement = f.emplacement
LEFT JOIN lignes l
  ON l.id_ligne = f.id_ligne;


ALTER TABLE uti.couche_livrable_t2h_maitresse
    ADD CONSTRAINT couche_livrable_t2h_maitresse_pk
    PRIMARY KEY (id);

CREATE UNIQUE INDEX idx_t2h_maitresse_emprise
    ON uti.couche_livrable_t2h_maitresse (id_emprise);

CREATE UNIQUE INDEX idx_t2h_maitresse_ligne_cote
    ON uti.couche_livrable_t2h_maitresse (
        id_ligne,
        emplacement
    );

CREATE INDEX idx_t2h_maitresse_geom
    ON uti.couche_livrable_t2h_maitresse
    USING gist (geom);


CREATE VIEW uti.v_t2h_maitresse_pair_impair_controle AS
SELECT
    COUNT(*) AS nb_entites,
    COUNT(DISTINCT id_ligne) AS nb_lignes,

    COUNT(*) FILTER (
        WHERE emplacement = 'PAIR'
    ) AS nb_pair,

    COUNT(*) FILTER (
        WHERE emplacement = 'IMPAIR'
    ) AS nb_impair,

    COUNT(*) FILTER (
        WHERE id_troncon IS NOT NULL
    ) AS nb_avec_troncons,

    COUNT(*) FILTER (
        WHERE nb_lots > 0
    ) AS nb_avec_lots,

    COUNT(*) FILTER (
        WHERE nb_zonages > 0
    ) AS nb_avec_zonage,

    COUNT(*) - 2 * COUNT(DISTINCT id_ligne)
        AS ecart_attendu

FROM uti.couche_livrable_t2h_maitresse;


DO $controle_pair_impair$
DECLARE
    r record;
    n_anomalies integer;
BEGIN
    SELECT *
    INTO r
    FROM uti.v_t2h_maitresse_pair_impair_controle;

    SELECT COUNT(*)
    INTO n_anomalies
    FROM (
        SELECT id_ligne
        FROM uti.couche_livrable_t2h_maitresse
        GROUP BY id_ligne
        HAVING COUNT(*) <> 2
            OR COUNT(*) FILTER (
                WHERE emplacement = 'PAIR'
            ) <> 1
            OR COUNT(*) FILTER (
                WHERE emplacement = 'IMPAIR'
            ) <> 1
    ) q;

    IF n_anomalies > 0 THEN
        RAISE EXCEPTION
            '% ligne(s) ne possèdent pas exactement PAIR et IMPAIR.',
            n_anomalies;
    END IF;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'COUCHE MAÎTRESSE V11.1';
    RAISE NOTICE '  lignes          : %', r.nb_lignes;
    RAISE NOTICE '  PAIR            : %', r.nb_pair;
    RAISE NOTICE '  IMPAIR          : %', r.nb_impair;
    RAISE NOTICE '  entités         : %', r.nb_entites;
    RAISE NOTICE '  avec tronçons   : %', r.nb_avec_troncons;
    RAISE NOTICE '  avec lots       : %', r.nb_avec_lots;
    RAISE NOTICE '  avec zonage     : %', r.nb_avec_zonage;
    RAISE NOTICE '--------------------------------------------------';
END
$controle_pair_impair$;