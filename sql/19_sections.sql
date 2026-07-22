-- ============================================================================
-- 19_sections.sql   —   DÉCOUPAGE EN SECTIONS (étape 4 du mandat)
-- ----------------------------------------------------------------------------
-- RÈGLES DU MANDAT :
--   « Association du zonage aux limites naturelles et infrastructurelles pour
--     réaliser le découpage des sections »
--   « Chaque géométrie de zonage doit constituer un tronçon ou section »
--   « Les zones qui sont sur les propriétés privées doivent constituer des
--     sections ou tronçons à part distincts »
--   « Les limites naturelles ou infrastructurelles (UTG, pont, infrastructure
--     de transport) servent de repère de création des tronçons »
--
-- UNE SECTION = EMPRISE AÉRIENNE D'UNE LIGNE x affectation PUM x UTG x régime foncier dominant
--
--   Trois causes de coupure, toutes exigées par le mandat :
--     ZONAGE          changement d'affectation PUM
--     LIMITE_UTG      franchissement d'une limite d'arrondissement ou de ville
--     REGIME_FONCIER  passage du domaine public au privé
--
-- POURQUOI DÉCOUPER PAR UTG : sans cela, une section chevauchant deux
--   territoires est attribuée en entier à celui de son centroïde. Pointe-Claire
--   comptait 47 pylônes et zéro section — un gestionnaire local n'aurait rien
--   vu de son territoire. Le découpage rend chaque UTG autonome.
--
--   La source est raw.limites_admin, dont dérive uti.utg (créé plus tard par
--   20b_utg.sql). Même géométrie, donc cohérence garantie.
--
-- RÉSIDUS HORS PUM : le PUM 2050 ne couvre QUE les 19 arrondissements de la
--   Ville de Montréal, pas les 15 villes liées de l'agglomération. Les parts
--   d'emprise non couvertes reçoivent zonage_affectation = HORS_PUM_2050 —
--   la lacune reste visible dans la donnée tout en étant traitée.
--
-- POURQUOI L'EMPRISE AÉRIENNE : elle porte la contrainte réglementaire et doit
--   être segmentée pour la gestion. Depuis la correction du script 18, chaque
--   emprise conserve id_ligne et dérive directement de geom_sol. L'emprise SOL
--   décrit l'occupation physique et n'a pas à être découpée par zonage.
--
-- PRÉREQUIS : 18_emprises.sql, raw.affectation_pum, raw.role_foncier,
--             raw.limites_admin
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 19
-- ============================================================================

TRUNCATE TABLE uti.t2h_elec_sections RESTART IDENTITY CASCADE;


-- ============================================================================
-- AJOUT DE TRAÇABILITÉ VERS LA LIGNE SOURCE
-- ============================================================================

ALTER TABLE uti.t2h_elec_sections
    ADD COLUMN IF NOT EXISTS id_ligne bigint;

CREATE INDEX IF NOT EXISTS idx_t2h_elec_sections_id_ligne
    ON uti.t2h_elec_sections (id_ligne);


-- ============================================================================
-- GARDE-FOU
-- ============================================================================

DO $garde$
BEGIN
    IF (SELECT count(*) FROM uti.t2h_elec_emprises
        WHERE type_emprise = 'AERIENNE') = 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        SELECT 'SECTIONS', 'BLOQUANT',
               'Aucune emprise aérienne à découper. Le découpage en sections est '
               'prêt mais sans objet.',
               'Produire les emprises (18_emprises.sql), puis relancer 19.'
        WHERE NOT EXISTS (
            SELECT 1 FROM uti.t2h_elec_journal_blocages
            WHERE etape = 'SECTIONS' AND severite = 'BLOQUANT');
        RAISE NOTICE '[SOMMEIL] 0 emprise aérienne -> 0 section.';
    END IF;
END
$garde$;


-- ============================================================================
-- PRÉ-VALIDATION DES COUCHES DE RÉFÉRENCE
-- ----------------------------------------------------------------------------
-- ST_MakeValid à l'intérieur d'un prédicat spatial défait l'index GiST et
-- provoque un effondrement des performances. On pré-valide dans des tables
-- temporaires indexées, puis on joint dessus.
-- ============================================================================

DROP TABLE IF EXISTS _pum_valide;
CREATE TEMP TABLE _pum_valide AS
SELECT
    row_number() OVER ()   AS gid,
    affectatio             AS affectation,
    ST_MakeValid(geometry) AS geom
FROM raw.affectation_pum
WHERE geometry IS NOT NULL;

CREATE INDEX ON _pum_valide USING GIST (geom);


DROP TABLE IF EXISTS _lots_valide;
CREATE TEMP TABLE _lots_valide AS
SELECT
    f.id_uev                           AS id_lot,
    f.code_utili,
    uti.f_regime_foncier(f.code_utili) AS regime,
    ST_MakeValid(f.geometry)           AS geom
FROM raw.role_foncier f
WHERE f.geometry IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM uti.t2h_elec_emprises e
      WHERE e.type_emprise = 'AERIENNE'
        AND ST_DWithin(e.geom, f.geometry, 1)
  );

CREATE INDEX ON _lots_valide USING GIST (geom);


-- Limites de gestion — source de uti.utg, créé plus tard par 20b
DO $utg_temp$
DECLARE
    col_nom text;
BEGIN
    SELECT column_name INTO col_nom
    FROM information_schema.columns
    WHERE table_schema = 'raw' AND table_name = 'limites_admin'
      AND lower(column_name) IN ('nom_arr', 'nom_officiel', 'arrondissement',
                                 'nom_arrond', 'nom', 'municipalite', 'nom_mun')
    ORDER BY array_position(
        ARRAY['nom_arr','nom_officiel','arrondissement','nom_arrond',
              'nom','municipalite','nom_mun'], lower(column_name))
    LIMIT 1;

    IF col_nom IS NULL THEN
        RAISE EXCEPTION 'Colonne de nom introuvable dans raw.limites_admin — '
                        'le découpage par UTG est impossible.';
    END IF;

    EXECUTE format($fmt$
        CREATE TEMP TABLE _utg_valide AS
        SELECT
            row_number() OVER ()   AS gid,
            a.%1$I::text           AS nom_utg,
            ST_MakeValid(a.geometry) AS geom
        FROM raw.limites_admin a
        WHERE a.geometry IS NOT NULL
    $fmt$, col_nom);

    CREATE INDEX ON _utg_valide USING GIST (geom);
    RAISE NOTICE '[OK] Limites de gestion préparées (colonne %)', col_nom;
END
$utg_temp$;


-- ============================================================================
-- 1 — SECTIONS COUVERTES PAR LE PUM
-- ----------------------------------------------------------------------------
-- Emprise x affectation x UTG. Le régime foncier dominant et le nombre de lots
-- sont attachés ensuite.
-- ============================================================================

INSERT INTO uti.t2h_elec_sections (
    id_treevans, id_emprise, id_corridor, id_ligne, ordre_section,
    motif_decoupe, zonage_affectation, regime_foncier, nb_lots,
    tension_kv, longueur_m, surface_m2, arrondissement, geom
)
WITH morceaux AS (
    SELECT
        e.id_emprise,
        e.id_corridor,
        e.id_ligne,
        e.tension_kv,
        p.affectation,
        u.nom_utg,
        ST_Multi(ST_CollectionExtract(
            ST_Intersection(ST_Intersection(e.geom, p.geom), u.geom), 3)) AS geom
    FROM uti.t2h_elec_emprises e
    JOIN _pum_valide p ON ST_Intersects(e.geom, p.geom)
    JOIN _utg_valide u ON ST_Intersects(e.geom, u.geom)
    WHERE e.type_emprise = 'AERIENNE'
),
valides AS (
    SELECT * FROM morceaux
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_Area(geom) > 1
),
enrichis AS (
    SELECT
        v.id_emprise,
        v.id_corridor,
        v.id_ligne,
        v.tension_kv,
        v.affectation,
        v.nom_utg,
        v.geom,
        COALESCE((
            SELECT l.regime
            FROM _lots_valide l
            WHERE ST_Intersects(v.geom, l.geom)
            GROUP BY l.regime
            ORDER BY sum(ST_Area(ST_Intersection(v.geom, l.geom))) DESC
            LIMIT 1
        ), 'PUBLIC') AS regime,
        (SELECT count(*) FROM _lots_valide l
         WHERE ST_Intersects(v.geom, l.geom)) AS nb_lots
    FROM valides v
)
SELECT
    'TVS-ELEC-SEC-' || LPAD(ROW_NUMBER() OVER (
        ORDER BY x.id_emprise, x.nom_utg, x.affectation)::text, 6, '0'),
    x.id_emprise,
    x.id_corridor,
    x.id_ligne,
    ROW_NUMBER() OVER (PARTITION BY x.id_emprise
                       ORDER BY x.nom_utg, x.affectation, x.regime),
    CASE WHEN x.regime = 'PRIVE' THEN 'REGIME_FONCIER' ELSE 'ZONAGE' END,
    x.affectation,
    x.regime,
    x.nb_lots,
    x.tension_kv,
    ROUND(ST_Perimeter(x.geom)::numeric, 2),
    ROUND(ST_Area(x.geom)::numeric, 2),
    x.nom_utg,
    x.geom
FROM enrichis x;


-- ============================================================================
-- 2 — SECTIONS RÉSIDUELLES — emprise hors couverture PUM 2050
-- ----------------------------------------------------------------------------
-- Le PUM 2050 est le plan d'urbanisme de la VILLE de Montréal. Il ne couvre pas
-- les 15 municipalités reconstituées de l'agglomération, que les corridors
-- électriques traversent pourtant.
--
-- Sans cette branche, près de 29 pour cent de l'emprise ne produirait AUCUNE
-- section, donc aucun emplacement, donc aucune relation aux lots — un
-- propriétaire de l'ouest de l'île serait absent du livrable alors qu'il a les
-- mêmes droits d'information qu'un Montréalais.
-- ============================================================================

INSERT INTO uti.t2h_elec_sections (
    id_treevans, id_emprise, id_corridor, id_ligne, ordre_section,
    motif_decoupe, zonage_affectation, regime_foncier, nb_lots,
    tension_kv, longueur_m, surface_m2, arrondissement, geom
)
WITH residu AS (
    -- Part de l'emprise que le PUM ne recouvre pas, découpée par UTG
    SELECT
        e.id_emprise,
        e.id_corridor,
        e.id_ligne,
        e.tension_kv,
        u.nom_utg,
        ST_Multi(ST_CollectionExtract(
            ST_Difference(
                ST_Intersection(e.geom, u.geom),
                COALESCE(
                    (SELECT ST_Union(p.geom) FROM _pum_valide p
                     WHERE ST_Intersects(e.geom, p.geom)),
                    ST_GeomFromText('POLYGON EMPTY', 2950))
            ), 3)) AS geom
    FROM uti.t2h_elec_emprises e
    JOIN _utg_valide u ON ST_Intersects(e.geom, u.geom)
    WHERE e.type_emprise = 'AERIENNE'
),
eclate AS (
    SELECT
        r.id_emprise,
        r.id_corridor,
        r.id_ligne,
        r.tension_kv,
        r.nom_utg,
        ST_Multi((ST_Dump(r.geom)).geom)::geometry(MultiPolygon, 2950) AS geom
    FROM residu r
    WHERE r.geom IS NOT NULL AND NOT ST_IsEmpty(r.geom)
),
valides AS (
    SELECT * FROM eclate WHERE ST_Area(geom) > 100
),
enrichis AS (
    SELECT
        v.id_emprise,
        v.id_corridor,
        v.id_ligne,
        v.tension_kv,
        v.nom_utg,
        v.geom,
        COALESCE((
            SELECT l.regime
            FROM _lots_valide l
            WHERE ST_Intersects(v.geom, l.geom)
            GROUP BY l.regime
            ORDER BY sum(ST_Area(ST_Intersection(v.geom, l.geom))) DESC
            LIMIT 1
        ), 'PUBLIC') AS regime,
        (SELECT count(*) FROM _lots_valide l
         WHERE ST_Intersects(v.geom, l.geom)) AS nb_lots
    FROM valides v
)
SELECT
    'TVS-ELEC-SEC-R' || LPAD(ROW_NUMBER() OVER (
        ORDER BY x.id_emprise, x.nom_utg)::text, 5, '0'),
    x.id_emprise,
    x.id_corridor,
    x.id_ligne,
    1000 + ROW_NUMBER() OVER (PARTITION BY x.id_emprise ORDER BY x.nom_utg),
    'LIMITE_UTG',
    'HORS_PUM_2050',
    x.regime,
    x.nb_lots,
    x.tension_kv,
    ROUND(ST_Perimeter(x.geom)::numeric, 2),
    ROUND(ST_Area(x.geom)::numeric, 2),
    x.nom_utg,
    x.geom
FROM enrichis x;


-- ============================================================================
-- CONSIGNATION
-- ============================================================================

DO $bilan$
DECLARE
    n_sec    integer;
    n_lignes integer;
    n_priv   integer;
    n_pub    integer;
    n_hors   integer;
    n_utg    integer;
    ha_tot   numeric;
    ha_empr  numeric;
BEGIN
    SELECT count(*) INTO n_sec FROM uti.t2h_elec_sections;
    SELECT count(DISTINCT id_ligne) INTO n_lignes
    FROM uti.t2h_elec_sections
    WHERE id_ligne IS NOT NULL;
    SELECT count(*) INTO n_priv FROM uti.t2h_elec_sections WHERE regime_foncier = 'PRIVE';
    SELECT count(*) INTO n_pub  FROM uti.t2h_elec_sections WHERE regime_foncier = 'PUBLIC';
    SELECT count(*) INTO n_hors FROM uti.t2h_elec_sections
        WHERE zonage_affectation = 'HORS_PUM_2050';
    SELECT count(DISTINCT arrondissement) INTO n_utg FROM uti.t2h_elec_sections;
    SELECT ROUND(sum(surface_m2)/10000.0, 1) INTO ha_tot FROM uti.t2h_elec_sections;
    SELECT ROUND(sum(surface_m2)/10000.0, 1) INTO ha_empr
        FROM uti.t2h_elec_emprises WHERE type_emprise = 'AERIENNE';

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE '  sections        : %  (% ha)', n_sec, ha_tot;
    RAISE NOTICE '  lignes couvertes : %', n_lignes;
    RAISE NOTICE '    PRIVE         : %', n_priv;
    RAISE NOTICE '    PUBLIC        : %', n_pub;
    RAISE NOTICE '    hors PUM      : %', n_hors;
    RAISE NOTICE '  territoires     : %', n_utg;
    RAISE NOTICE '  emprise source  : % ha   <- doit correspondre', ha_empr;
    RAISE NOTICE '--------------------------------------------------';

    IF n_sec > 0 THEN
        DELETE FROM uti.t2h_elec_journal_blocages
        WHERE etape = 'SECTIONS' AND severite = 'BLOQUANT';
    END IF;

    -- Contrôle de partition : sections = emprise, à l'arrondi près
    IF ha_empr IS NOT NULL AND abs(ha_tot - ha_empr) > 1 THEN
        RAISE NOTICE '[AVERT] Écart de % ha entre sections et emprise.', ha_tot - ha_empr;
    END IF;

    IF n_hors > 0 THEN
        DELETE FROM uti.t2h_elec_journal_blocages WHERE etape = 'COUVERTURE_PUM';

        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        VALUES ('COUVERTURE_PUM', 'AVERTISSEMENT',
                format('%s section(s) portent zonage_affectation = HORS_PUM_2050. '
                       'Le PUM 2050 ne couvre que les 19 arrondissements de la '
                       'Ville de Montréal, pas les 15 villes liées de '
                       'l''agglomération que les corridors traversent aussi.', n_hors),
                'Obtenir les plans d''urbanisme des villes liées concernées — '
                'Baie-D''Urfé, Beaconsfield, Dorval, Kirkland, Pointe-Claire, '
                'Sainte-Anne-de-Bellevue, Montréal-Est — pour affecter ces sections.');
    END IF;
END
$bilan$;


-- ============================================================================
-- VUES DE SYNTHÈSE (profil Gestionnaire)
-- ============================================================================

-- DROP explicite : CREATE OR REPLACE refuse de renommer une colonne existante
DROP VIEW IF EXISTS uti.v_t2h_elec_sections_synthese CASCADE;

CREATE VIEW uti.v_t2h_elec_sections_synthese AS
SELECT
    zonage_affectation,
    regime_foncier,
    count(*)                          AS nb_sections,
    count(DISTINCT id_ligne)          AS nb_lignes,
    sum(nb_lots)                      AS nb_lots_touches,
    ROUND(sum(surface_m2))            AS surface_m2,
    ROUND(sum(surface_m2)/10000.0, 2) AS surface_ha,
    count(DISTINCT arrondissement)    AS nb_territoires
FROM uti.t2h_elec_sections
GROUP BY zonage_affectation, regime_foncier
ORDER BY surface_m2 DESC;

COMMENT ON VIEW uti.v_t2h_elec_sections_synthese IS
  'Sections par affectation PUM et régime foncier. Les surfaces sont INDICATIVES '
  'tant que les largeurs d''emprise ne sont pas validées par Hydro-Québec.';


DROP VIEW IF EXISTS uti.v_t2h_elec_sections_par_territoire CASCADE;

CREATE VIEW uti.v_t2h_elec_sections_par_territoire AS
SELECT
    arrondissement                    AS territoire,
    count(*)                          AS nb_sections,
    count(DISTINCT id_ligne)          AS nb_lignes,
    count(*) FILTER (WHERE zonage_affectation = 'HORS_PUM_2050') AS dont_hors_pum,
    count(*) FILTER (WHERE regime_foncier = 'PRIVE')             AS dont_privees,
    sum(nb_lots)                      AS nb_lots_touches,
    ROUND(sum(surface_m2)/10000.0, 2) AS surface_ha
FROM uti.t2h_elec_sections
GROUP BY arrondissement
ORDER BY surface_ha DESC;

COMMENT ON VIEW uti.v_t2h_elec_sections_par_territoire IS
  'Sections par territoire de gestion. Le découpage aux limites d''UTG garantit '
  'que chaque arrondissement ou ville liée voit ses propres sections.';