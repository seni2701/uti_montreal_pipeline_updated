-- ============================================================================
-- 23_couche_maitresse_hydroelectrique.sql
-- LIVRABLE D V10.1 — COUCHE MAÎTRESSE CORRIGÉE
-- ----------------------------------------------------------------------------
-- Correction :
--   la géométrie de chaque entité est construite directement à partir du
--   tronçon électrique, avec un buffer unilatéral :
--       IMPAIR = côté gauche
--       PAIR   = côté droit
--
-- Cela garantit exactement :
--   1 tronçon x 1 côté PAIR
--   1 tronçon x 1 côté IMPAIR
--
-- Avec 1 060 tronçons : 2 120 entités attendues.
-- ============================================================================


DROP VIEW IF EXISTS uti.v_t2h_maitresse_anomalies CASCADE;
DROP VIEW IF EXISTS uti.v_t2h_maitresse_controle CASCADE;
DROP TABLE IF EXISTS uti.couche_livrable_t2h_maitresse CASCADE;


CREATE TABLE uti.couche_livrable_t2h_maitresse AS
WITH parametres_ligne AS (
    SELECT
        id_ligne,
        MAX(reseau) AS reseau,
        MAX(exploitant) AS exploitant,
        MAX(tension_kv) AS tension_kv,
        MAX(largeur_buffer_m) AS largeur_buffer_m,
        MAX(largeur_emprise_totale_m) AS largeur_emprise_totale_m,
        MAX(longueur_ligne_sol_m) AS longueur_ligne_sol_m,
        MAX(numeros_lots) AS numeros_lots,
        MAX(regime_foncier) AS regime_foncier,
        MAX(statut_cadastre) AS statut_cadastre,
        MAX(emprise_sol_m2) AS emprise_sol_m2,
        MAX(empreinte_ligne_sol_m2) AS empreinte_ligne_sol_m2,
        MAX(hauteur_ligne_m) AS hauteur_ligne_m,
        MAX(hauteur_vegetation_max_m) AS hauteur_vegetation_max_m,
        MAX(emprise_chute_m2) AS emprise_chute_m2
    FROM uti.couche_livrable_t2h_sol
    GROUP BY id_ligne
),
troncons_cotes AS (
    SELECT
        t.id_troncon,
        t.id_ligne,
        t.no_partie,
        t.ordre_troncon,
        t.id_pylone_debut,
        t.id_pylone_fin,
        t.ids_pylones_debut,
        t.ids_pylones_fin,
        t.type_troncon,
        t.chainage_debut_m,
        t.chainage_fin_m,
        t.longueur_m AS longueur_troncon_m,
        t.geom AS geom_troncon,

        p.reseau,
        p.exploitant,
        p.tension_kv,
        p.largeur_buffer_m,
        p.largeur_emprise_totale_m,
        p.longueur_ligne_sol_m,
        p.numeros_lots,
        p.regime_foncier,
        p.statut_cadastre,
        p.emprise_sol_m2,
        p.empreinte_ligne_sol_m2,
        p.hauteur_ligne_m,
        p.hauteur_vegetation_max_m,
        p.emprise_chute_m2,

        'IMPAIR'::text AS emplacement,

        ST_Multi(
            ST_CollectionExtract(
                ST_MakeValid(
                    ST_Buffer(
                        t.geom,
                        p.largeur_buffer_m,
                        'side=left endcap=flat join=mitre'
                    )
                ),
                3
            )
        )::geometry(MultiPolygon, 2950) AS geom

    FROM uti.t2h_elec_troncons t
    JOIN parametres_ligne p
      ON p.id_ligne = t.id_ligne

    UNION ALL

    SELECT
        t.id_troncon,
        t.id_ligne,
        t.no_partie,
        t.ordre_troncon,
        t.id_pylone_debut,
        t.id_pylone_fin,
        t.ids_pylones_debut,
        t.ids_pylones_fin,
        t.type_troncon,
        t.chainage_debut_m,
        t.chainage_fin_m,
        t.longueur_m AS longueur_troncon_m,
        t.geom AS geom_troncon,

        p.reseau,
        p.exploitant,
        p.tension_kv,
        p.largeur_buffer_m,
        p.largeur_emprise_totale_m,
        p.longueur_ligne_sol_m,
        p.numeros_lots,
        p.regime_foncier,
        p.statut_cadastre,
        p.emprise_sol_m2,
        p.empreinte_ligne_sol_m2,
        p.hauteur_ligne_m,
        p.hauteur_vegetation_max_m,
        p.emprise_chute_m2,

        'PAIR'::text AS emplacement,

        ST_Multi(
            ST_CollectionExtract(
                ST_MakeValid(
                    ST_Buffer(
                        t.geom,
                        p.largeur_buffer_m,
                        'side=right endcap=flat join=mitre'
                    )
                ),
                3
            )
        )::geometry(MultiPolygon, 2950) AS geom

    FROM uti.t2h_elec_troncons t
    JOIN parametres_ligne p
      ON p.id_ligne = t.id_ligne
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY id_ligne, ordre_troncon, emplacement
    )::bigint AS id,

    id_troncon || '-'
    || CASE
        WHEN emplacement = 'PAIR' THEN 'P'
        ELSE 'I'
    END AS id_segment_emprise,

    id_troncon,
    id_ligne,
    no_partie,
    ordre_troncon,

    emplacement,
    type_troncon,

    id_pylone_debut,
    id_pylone_fin,
    ids_pylones_debut,
    ids_pylones_fin,

    reseau,
    exploitant,
    tension_kv,

    chainage_debut_m,
    chainage_fin_m,
    longueur_troncon_m,

    largeur_buffer_m,
    largeur_emprise_totale_m,
    longueur_ligne_sol_m,

    numeros_lots,
    regime_foncier,
    statut_cadastre,

    ROUND(ST_Area(geom)::numeric, 2)
        AS surface_emprise_segment_m2,

    emprise_sol_m2,
    empreinte_ligne_sol_m2,

    hauteur_ligne_m,
    hauteur_vegetation_max_m,
    emprise_chute_m2,

    ST_AsText(geom_troncon) AS geom_troncon_wkt,

    'BUFFER_UNILATERAL_TRONCON'::text
        AS methode_partition,

    geom

FROM troncons_cotes
WHERE geom IS NOT NULL
  AND NOT ST_IsEmpty(geom)
  AND ST_Area(geom) > 0.01;


ALTER TABLE uti.couche_livrable_t2h_maitresse
    ADD CONSTRAINT couche_livrable_t2h_maitresse_pk
    PRIMARY KEY (id);

CREATE UNIQUE INDEX idx_t2h_maitresse_code
    ON uti.couche_livrable_t2h_maitresse (
        id_segment_emprise
    );

CREATE INDEX idx_t2h_maitresse_troncon
    ON uti.couche_livrable_t2h_maitresse (
        id_troncon,
        emplacement
    );

CREATE INDEX idx_t2h_maitresse_ligne
    ON uti.couche_livrable_t2h_maitresse (
        id_ligne,
        ordre_troncon
    );

CREATE INDEX idx_t2h_maitresse_geom
    ON uti.couche_livrable_t2h_maitresse
    USING gist (geom);


CREATE VIEW uti.v_t2h_maitresse_anomalies AS
SELECT
    id_troncon,
    COUNT(*) AS nb_entites,
    COUNT(*) FILTER (
        WHERE emplacement = 'PAIR'
    ) AS nb_pair,
    COUNT(*) FILTER (
        WHERE emplacement = 'IMPAIR'
    ) AS nb_impair
FROM uti.couche_livrable_t2h_maitresse
GROUP BY id_troncon
HAVING COUNT(*) <> 2
    OR COUNT(*) FILTER (
        WHERE emplacement = 'PAIR'
    ) <> 1
    OR COUNT(*) FILTER (
        WHERE emplacement = 'IMPAIR'
    ) <> 1;


CREATE VIEW uti.v_t2h_maitresse_controle AS
SELECT
    COUNT(*) AS nb_entites,
    COUNT(DISTINCT id_troncon) AS nb_troncons,
    COUNT(DISTINCT id_ligne) AS nb_lignes,

    COUNT(*) FILTER (
        WHERE emplacement = 'PAIR'
    ) AS nb_pair,

    COUNT(*) FILTER (
        WHERE emplacement = 'IMPAIR'
    ) AS nb_impair,

    ROUND(
        SUM(surface_emprise_segment_m2)::numeric,
        2
    ) AS surface_cumulee_m2

FROM uti.couche_livrable_t2h_maitresse;


DO $controle_maitresse$
DECLARE
    n_troncons_source integer;
    n_troncons_maitresse integer;
    n_anomalies integer;
    n_entites integer;
BEGIN
    SELECT COUNT(*)
    INTO n_troncons_source
    FROM uti.t2h_elec_troncons;

    SELECT
        COUNT(DISTINCT id_troncon),
        COUNT(*)
    INTO
        n_troncons_maitresse,
        n_entites
    FROM uti.couche_livrable_t2h_maitresse;

    SELECT COUNT(*)
    INTO n_anomalies
    FROM uti.v_t2h_maitresse_anomalies;

    IF n_troncons_maitresse <> n_troncons_source THEN
        RAISE EXCEPTION
            'Couche maîtresse incomplète : % tronçons sources, % intégrés.',
            n_troncons_source,
            n_troncons_maitresse;
    END IF;

    IF n_entites <> 2 * n_troncons_source THEN
        RAISE EXCEPTION
            'Nombre inattendu : % entités pour % tronçons.',
            n_entites,
            n_troncons_source;
    END IF;

    IF n_anomalies > 0 THEN
        RAISE EXCEPTION
            '% anomalie(s) détectée(s) dans la couche maîtresse.',
            n_anomalies;
    END IF;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'COUCHE MAÎTRESSE HYDROÉLECTRIQUE V10.1';
    RAISE NOTICE '  tronçons intégrés : %', n_troncons_maitresse;
    RAISE NOTICE '  entités finales    : %', n_entites;
    RAISE NOTICE '  anomalies          : %', n_anomalies;
    RAISE NOTICE '--------------------------------------------------';
END
$controle_maitresse$;
