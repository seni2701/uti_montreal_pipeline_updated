-- ============================================================================
-- 18_emprises.sql   —   EMPRISES DÉRIVÉES DES LIGNES PROJETÉES AU SOL
-- ----------------------------------------------------------------------------
-- Produit DEUX emprises PAR LIGNE :
--
--   AERIENNE  bande réglementaire obtenue par buffer de geom_sol selon la
--             demi-largeur associée à la tension de la ligne.
--
--   SOL       empreinte physique et d'accès obtenue par un buffer dont la
--             demi-largeur couvre les bases de pylônes agrandies de 1 m,
--             avec 2 m supplémentaires autour du corridor.
--
-- La ligne reste une géométrie linéaire. geom_sol est sa projection 2D au sol.
-- Les emprises sont les polygones dérivés de cette projection.
--
-- CORRECTION : l'ancienne version créait 23 emprises par type, soit une par
-- corridor. Cette version conserve la traçabilité de toutes les lignes et produit
-- une emprise distincte pour chaque ligne admissible. id_corridor reste présent
-- pour permettre les regroupements et les analyses à l'échelle du corridor.
--
-- PRÉREQUIS : 17_socle_geometrique.sql, uti.t2h_elec_regles_degagement
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 18
-- ============================================================================

TRUNCATE TABLE uti.t2h_elec_zones_securite RESTART IDENTITY CASCADE;
TRUNCATE TABLE uti.t2h_elec_emprises       RESTART IDENTITY CASCADE;


-- ============================================================================
-- AJOUT DE TRAÇABILITÉ VERS LA LIGNE SOURCE
-- ============================================================================

ALTER TABLE uti.t2h_elec_emprises
    ADD COLUMN IF NOT EXISTS id_ligne bigint;

CREATE INDEX IF NOT EXISTS idx_t2h_elec_emprises_id_ligne
    ON uti.t2h_elec_emprises (id_ligne);


-- ============================================================================
-- GARDE-FOU — TOUTES LES LIGNES DOIVENT AVOIR UNE PROJECTION AU SOL
-- ============================================================================

DO $garde_sol$
DECLARE
    n_total integer;
    n_sol   integer;
BEGIN
    SELECT count(*) INTO n_total FROM uti.t2h_elec_lignes;
    SELECT count(*) INTO n_sol
    FROM uti.t2h_elec_lignes
    WHERE geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(geom_sol);

    IF n_total = 0 THEN
        RAISE EXCEPTION 'Aucune ligne dans uti.t2h_elec_lignes. Relancer 17.';
    END IF;

    IF n_sol < n_total THEN
        RAISE EXCEPTION '% ligne(s) sur % n''ont pas de geom_sol. Corriger 17 avant de créer les emprises.',
                        n_total - n_sol, n_total;
    END IF;
END
$garde_sol$;


-- ============================================================================
-- Compatibilité avec la contrainte origine_geom_check du schéma :
-- les valeurs restent BUFFER_REGLEMENTAIRE, BUFFER_HYPOTHESE et
-- EMPREINTE_PYLONE. La traçabilité de la projection au sol est portée par
-- id_ligne et par geom_sol, sans modifier le domaine contrôlé existant.
--
-- 1 — EMPRISE AÉRIENNE PAR LIGNE
-- ----------------------------------------------------------------------------
-- Le buffer est appliqué à geom_sol. La largeur totale de l'emprise vaut
-- 2 x demi_largeur_m. Les extrémités sont plates pour éviter de prolonger
-- artificiellement la servitude au-delà des extrémités de la ligne source.
-- ============================================================================

INSERT INTO uti.t2h_elec_emprises (
    id_treevans, id_corridor, id_ligne, id_regle, type_emprise,
    origine_geom, licence_source, tension_kv, demi_largeur_m, statut_regle,
    surface_m2, arrondissement, id_utg, geom
)
WITH buffers AS (
    SELECT
        l.id_ligne,
        l.id_corridor,
        l.arrondissement,
        l.tension_kv,
        g.id_regle,
        g.demi_largeur_m,
        g.statut,
        ST_Multi(
            ST_CollectionExtract(
                ST_Buffer(
                    l.geom_sol,
                    g.demi_largeur_m,
                    'endcap=flat join=mitre'
                ),
                3
            )
        )::geometry(MultiPolygon, 2950) AS geom
    FROM uti.t2h_elec_lignes l
    JOIN uti.t2h_elec_regles_degagement g
      ON g.reseau = l.reseau
     AND g.demi_largeur_m IS NOT NULL
     AND (
            (g.tension_kv_min IS NULL
             AND g.tension_kv_max IS NULL
             AND l.tension_kv IS NULL)
         OR l.tension_kv BETWEEN g.tension_kv_min AND g.tension_kv_max
     )
    WHERE l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
)
SELECT
    'TVS-ELEC-EMP-AER-' || LPAD(
        ROW_NUMBER() OVER (ORDER BY b.id_ligne)::text,
        6,
        '0'
    ),
    b.id_corridor,
    b.id_ligne,
    b.id_regle,
    'AERIENNE',
    CASE b.statut
        WHEN 'VALIDE' THEN 'BUFFER_REGLEMENTAIRE'
        ELSE 'BUFFER_HYPOTHESE'
    END,
    'CC-BY',
    b.tension_kv,
    b.demi_largeur_m,
    b.statut,
    ROUND(ST_Area(b.geom)::numeric, 2),
    b.arrondissement,
    NULL,
    b.geom
FROM buffers b
WHERE b.geom IS NOT NULL
  AND NOT ST_IsEmpty(b.geom)
  AND ST_Area(b.geom) > 0;


-- ============================================================================
-- 2 — EMPRISE AU SOL PAR LIGNE
-- ----------------------------------------------------------------------------
-- L'empreinte SOL est constituée :
--   1. d'un buffer centré sur geom_sol
--   2. d'une demi-largeur ajustée à la distance du pylône le plus éloigné
--   3. d'une marge supplémentaire de 2 m
--   4. de l'union avec les polygones de pylônes agrandis de 1 m
--
-- Le rattachement pylône-ligne reste indicatif lorsque plusieurs circuits sont
-- parallèles. id_corridor demeure la clé de regroupement fiable.
-- ============================================================================

INSERT INTO uti.t2h_elec_emprises (
    id_treevans, id_corridor, id_ligne, id_regle, type_emprise,
    origine_geom, licence_source, tension_kv, demi_largeur_m, statut_regle,
    surface_m2, arrondissement, id_utg, geom
)
WITH parametres AS (
    -- Agrandissement renforcé des polygones de pylônes :
    --   1 m autour de la géométrie nominale de chaque pylône;
    --   2 m supplémentaires pour déterminer la largeur du corridor.
    -- La largeur finale atteint donc au minimum 3 m au-delà de l'enveloppe
    -- nominale du pylône le plus éloigné de l'axe.
    SELECT
        2.0::double precision AS marge_axe_pylone_m,
        1.0::double precision AS marge_geom_pylone_m
),
pylones_prepares AS (
    SELECT
        p.id_ligne,
        ST_Multi(
            ST_CollectionExtract(
                ST_Buffer(
                    ST_CollectionExtract(
                        ST_MakeValid(p.geom_polygone),
                        3
                    ),
                    prm.marge_geom_pylone_m
                ),
                3
            )
        )::geometry(MultiPolygon, 2950) AS geom_pylone_securisee
    FROM uti.t2h_elec_pylones p
    CROSS JOIN parametres prm
    WHERE p.id_ligne IS NOT NULL
      AND p.geom_polygone IS NOT NULL
      AND NOT ST_IsEmpty(p.geom_polygone)
),
pylones_ligne AS (
    SELECT
        pp.id_ligne,
        ST_UnaryUnion(
            ST_Collect(pp.geom_pylone_securisee)
        ) AS geom_pylones,

        MAX(
            ST_Distance(
                (dp).geom,
                l.geom_sol
            )
        ) AS distance_max_pylone_m

    FROM pylones_prepares pp
    JOIN uti.t2h_elec_lignes l
      ON l.id_ligne = pp.id_ligne
    CROSS JOIN LATERAL ST_DumpPoints(
        pp.geom_pylone_securisee
    ) dp
    WHERE pp.geom_pylone_securisee IS NOT NULL
      AND NOT ST_IsEmpty(pp.geom_pylone_securisee)
      AND l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
    GROUP BY pp.id_ligne
),
empreintes AS (
    SELECT
        l.id_ligne,
        l.id_corridor,
        l.arrondissement,
        l.tension_kv,
        g.id_regle,
        g.passage_acces_m,
        g.statut,

        GREATEST(
            g.passage_acces_m / 2.0,
            COALESCE(
                p.distance_max_pylone_m + prm.marge_axe_pylone_m,
                0
            )
        ) AS demi_largeur_effective_m,

        ST_Multi(
            ST_CollectionExtract(
                ST_UnaryUnion(
                    ST_Collect(
                        ST_Buffer(
                            l.geom_sol,
                            GREATEST(
                                g.passage_acces_m / 2.0,
                                COALESCE(
                                    p.distance_max_pylone_m
                                    + prm.marge_axe_pylone_m,
                                    0
                                )
                            ),
                            'endcap=flat join=mitre'
                        ),
                        p.geom_pylones
                    )
                ),
                3
            )
        )::geometry(MultiPolygon, 2950) AS geom

    FROM uti.t2h_elec_lignes l
    JOIN uti.t2h_elec_regles_degagement g
      ON g.reseau = l.reseau
     AND g.passage_acces_m IS NOT NULL
     AND (
            (g.tension_kv_min IS NULL
             AND g.tension_kv_max IS NULL
             AND l.tension_kv IS NULL)
         OR l.tension_kv BETWEEN g.tension_kv_min AND g.tension_kv_max
     )
    CROSS JOIN parametres prm
    LEFT JOIN pylones_ligne p
      ON p.id_ligne = l.id_ligne
    WHERE l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
)
SELECT
    'TVS-ELEC-EMP-SOL-' || LPAD(
        ROW_NUMBER() OVER (ORDER BY e.id_ligne)::text,
        6,
        '0'
    ),
    e.id_corridor,
    e.id_ligne,
    e.id_regle,
    'SOL',
    'EMPREINTE_PYLONE',
    'CC-BY',
    e.tension_kv,
    e.demi_largeur_effective_m,
    e.statut,
    ROUND(ST_Area(e.geom)::numeric, 2),
    e.arrondissement,
    NULL,
    e.geom
FROM empreintes e
WHERE e.geom IS NOT NULL
  AND NOT ST_IsEmpty(e.geom)
  AND ST_Area(e.geom) > 0;


-- ============================================================================
-- ============================================================================
-- CONTRÔLE BLOQUANT — TOUS LES PYLÔNES DOIVENT ÊTRE COUVERTS
-- ============================================================================

DO $controle_couverture_pylones$
DECLARE
    n_total integer;
    n_couverts integer;
    n_non_couverts integer;
BEGIN
    SELECT
        count(*),
        count(*) FILTER (
            WHERE ST_Covers(
                e.geom,
                ST_CollectionExtract(
                    ST_MakeValid(p.geom_polygone),
                    3
                )
            )
        )
    INTO n_total, n_couverts
    FROM uti.t2h_elec_pylones p
    JOIN uti.t2h_elec_emprises e
      ON e.id_ligne = p.id_ligne
     AND e.type_emprise = 'SOL'
    WHERE p.geom_polygone IS NOT NULL
      AND NOT ST_IsEmpty(p.geom_polygone);

    n_non_couverts := n_total - n_couverts;

    RAISE NOTICE 'Pylônes couverts : % / %', n_couverts, n_total;

    IF n_non_couverts > 0 THEN
        RAISE EXCEPTION
            '% pylône(s) restent hors des emprises SOL.',
            n_non_couverts;
    END IF;
END
$controle_couverture_pylones$;


-- ============================================================================
-- 3 — ZONES DE SÉCURITÉ
-- ============================================================================

INSERT INTO uti.t2h_elec_zones_securite (
    id_emprise, type_zone, hauteur_veg_max_m, largeur_m,
    symbologie, statut_regle, surface_m2, geom
)
SELECT
    e.id_emprise,
    'DEGAGEMENT_VEGETATION',
    g.hauteur_veg_max_m,
    g.demi_largeur_m,
    'HACHURE_ROUGE',
    g.statut,
    e.surface_m2,
    e.geom
FROM uti.t2h_elec_emprises e
JOIN uti.t2h_elec_regles_degagement g
  ON g.id_regle = e.id_regle
WHERE e.type_emprise = 'AERIENNE'
  AND g.hauteur_veg_max_m IS NOT NULL;


-- ============================================================================
-- 4 — CONSIGNATION
-- ============================================================================

DO $bilan$
DECLARE
    n_lignes        integer;
    n_aer           integer;
    n_sol           integer;
    n_lignes_aer    integer;
    n_lignes_sol    integer;
    n_hyp           integer;
    ha_aer          numeric;
    ha_sol          numeric;
BEGIN
    SELECT count(*) INTO n_lignes
    FROM uti.t2h_elec_lignes
    WHERE geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(geom_sol);

    SELECT count(*),
           count(DISTINCT id_ligne),
           ROUND(coalesce(sum(surface_m2), 0) / 10000.0, 1)
      INTO n_aer, n_lignes_aer, ha_aer
    FROM uti.t2h_elec_emprises
    WHERE type_emprise = 'AERIENNE';

    SELECT count(*),
           count(DISTINCT id_ligne),
           ROUND(coalesce(sum(surface_m2), 0) / 10000.0, 1)
      INTO n_sol, n_lignes_sol, ha_sol
    FROM uti.t2h_elec_emprises
    WHERE type_emprise = 'SOL';

    SELECT count(*) INTO n_hyp
    FROM uti.t2h_elec_emprises
    WHERE statut_regle = 'HYPOTHESE';

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE '  lignes au sol       : %', n_lignes;
    RAISE NOTICE '  emprises AERIENNE   : %  (% lignes, % ha)',
                 n_aer, n_lignes_aer, ha_aer;
    RAISE NOTICE '  emprises SOL        : %  (% lignes, % ha)',
                 n_sol, n_lignes_sol, ha_sol;
    RAISE NOTICE '  sur hypothèse       : % / %', n_hyp, n_aer + n_sol;
    RAISE NOTICE '--------------------------------------------------';

    DELETE FROM uti.t2h_elec_journal_blocages
    WHERE etape = 'EMPRISES';

    IF n_aer = 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (
            etape, severite, motif, action_requise
        )
        VALUES (
            'EMPRISES',
            'BLOQUANT',
            'Aucune emprise produite à partir des lignes projetées au sol.',
            'Vérifier geom_sol, les tensions et les règles de dégagement, puis relancer 18.'
        );
    ELSE
        IF n_lignes_aer < n_lignes THEN
            INSERT INTO uti.t2h_elec_journal_blocages (
                etape, severite, motif, action_requise
            )
            VALUES (
                'EMPRISES',
                'AVERTISSEMENT',
                format(
                    '%s ligne(s) projetée(s) au sol n''ont pas produit d''emprise aérienne.',
                    n_lignes - n_lignes_aer
                ),
                'Contrôler les tensions non attribuées et la couverture des règles de dégagement.'
            );
        END IF;

        IF n_lignes_sol < n_lignes THEN
            INSERT INTO uti.t2h_elec_journal_blocages (
                etape, severite, motif, action_requise
            )
            VALUES (
                'EMPRISES',
                'AVERTISSEMENT',
                format(
                    '%s ligne(s) projetée(s) au sol n''ont pas produit d''emprise SOL.',
                    n_lignes - n_lignes_sol
                ),
                'Contrôler passage_acces_m dans les règles de dégagement.'
            );
        END IF;
    END IF;

    IF n_hyp > 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (
            etape, severite, motif, action_requise
        )
        VALUES (
            'EMPRISES',
            'AVERTISSEMENT',
            format(
                '%s emprise(s) reposent sur une largeur HYPOTHESE. Les surfaces annoncées (%s ha en aérien) restent indicatives.',
                n_hyp,
                ha_aer
            ),
            'Obtenir le barème des largeurs auprès d''Hydro-Québec, mettre à jour 16_referentiels et relancer 18 à 21.'
        );
    END IF;
END
$bilan$;


-- ============================================================================
-- FIN 18_emprises.sql
-- ============================================================================