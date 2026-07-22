-- ============================================================================
-- 20_emplacements.sql   —   EMPLACEMENTS ET COHABITATION (étapes 5 et 6)
-- ----------------------------------------------------------------------------
-- ÉTAPE 5 — MATÉRIALISATION DES EMPLACEMENTS
--   « Les orientations constituent la première considération, ensuite les
--     activités d'exploitation ou de voisinage et les adresses ou non de lieu. »
--
--   L'emplacement est le pendant électrique du parterre pair/impair routier :
--   la plus petite représentation spatiale de l'UTI. L'axe de référence n'est
--   pas la rue ni le corridor fusionné, mais geom_sol de la ligne source.
--
--   CORRECTION 2026-07-18 : la version précédente attribuait une orientation
--   par section sans la DÉCOUPER — produisant un emplacement identique à sa
--   section, donc aucune finesse supplémentaire. Cette version SCINDE
--   réellement chaque section par l'axe projeté au sol de sa ligne, produisant
--   GAUCHE et un emplacement DROITE, exactement comme le parterre pair et le
--   parterre impair encadrent une rue.
--
--   Une section que l'axe ne traverse pas entièrement reste en un seul morceau,
--   avec l'orientation de son centroïde. id_ligne est conservé jusqu'au livrable.
--
-- ÉTAPE 6 — RELATIONS DE COHABITATION
--   « Le propriétaire doit pouvoir visualiser les parties de son lot qui ne lui
--     sont pas accessibles. Le gestionnaire doit pouvoir consulter les espaces
--     de sécurité appartenant à des propriétaires privés. »
--   « Établir une relation qui peut être activée ou désactivée. »
--
-- PRÉREQUIS : 19_sections.sql
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 20
-- ============================================================================

TRUNCATE TABLE uti.t2h_elec_rel_lots      RESTART IDENTITY CASCADE;
TRUNCATE TABLE uti.t2h_elec_emplacements  RESTART IDENTITY CASCADE;


-- ============================================================================
-- AJOUT DE TRAÇABILITÉ VERS LA LIGNE SOURCE
-- ============================================================================

ALTER TABLE uti.t2h_elec_emplacements
    ADD COLUMN IF NOT EXISTS id_ligne bigint;

CREATE INDEX IF NOT EXISTS idx_t2h_elec_emplacements_id_ligne
    ON uti.t2h_elec_emplacements (id_ligne);


-- ============================================================================
-- GARDE-FOU
-- ============================================================================

DO $garde$
BEGIN
    IF (SELECT count(*) FROM uti.t2h_elec_sections) = 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        SELECT 'EMPLACEMENTS', 'BLOQUANT',
               'Aucune section à subdiviser (cascade du blocage amont).',
               'Débloquer les emprises puis les sections, et relancer 20.'
        WHERE NOT EXISTS (
            SELECT 1 FROM uti.t2h_elec_journal_blocages
            WHERE etape = 'EMPLACEMENTS' AND severite = 'BLOQUANT');
        RAISE NOTICE '[SOMMEIL] 0 section -> 0 emplacement.';
    END IF;
END
$garde$;


-- ============================================================================
-- FONCTION — de quel côté de l'axe se trouve une géométrie ?
-- ----------------------------------------------------------------------------
-- Le côté est donné par le signe du sinus de l'écart entre deux azimuts :
--   - celui de l'axe local (segment le plus proche de geom_sol)
--   - celui du vecteur axe -> point testé
-- Sinus positif = GAUCHE, négatif = DROITE.
-- ============================================================================

CREATE OR REPLACE FUNCTION uti.f_cote_axe(p_geom geometry, p_axe geometry)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
    p_test   geometry := ST_PointOnSurface(p_geom);
    l_brin   geometry;
    p_proj   geometry;
    frac     double precision;
    p_avant  geometry;
    p_apres  geometry;
    az_axe   double precision;
    az_pt    double precision;
BEGIN
    -- Brin linéaire de geom_sol le plus proche du point testé.
    -- Une ligne source peut rester multipartite après normalisation. On travaille
    -- donc sur un seul brin, choisi par proximité.
    SELECT d.geom INTO l_brin
    FROM ST_Dump(p_axe) d
    WHERE GeometryType(d.geom) = 'LINESTRING'
    ORDER BY ST_Distance(d.geom, p_test)
    LIMIT 1;

    IF l_brin IS NULL THEN
        RETURN 'AXIALE';
    END IF;

    p_proj := ST_ClosestPoint(l_brin, p_test);

    -- Un morceau centré sur l'axe est réellement AXIALE
    IF ST_DWithin(p_proj, p_test, 0.01) THEN
        RETURN 'AXIALE';
    END IF;

    -- Direction LOCALE de l'axe, prise sur un court segment autour de la
    -- projection. Utiliser les extrémités du brin fausserait le côté sur les
    -- tracés sinueux.
    frac    := ST_LineLocatePoint(l_brin, p_proj);
    p_avant := ST_LineInterpolatePoint(l_brin, greatest(frac - 0.01, 0));
    p_apres := ST_LineInterpolatePoint(l_brin, least(frac + 0.01, 1));

    IF ST_DWithin(p_avant, p_apres, 0.01) THEN
        RETURN 'AXIALE';
    END IF;

    az_axe := ST_Azimuth(p_avant, p_apres);
    az_pt  := ST_Azimuth(p_proj, p_test);

    IF az_axe IS NULL OR az_pt IS NULL THEN
        RETURN 'AXIALE';
    END IF;

    RETURN CASE WHEN sin(az_pt - az_axe) >= 0 THEN 'GAUCHE' ELSE 'DROITE' END;
END
$fn$;

COMMENT ON FUNCTION uti.f_cote_axe(geometry, geometry) IS
  'Côté d''une géométrie par rapport à geom_sol de la ligne source. Travaille '
  'sur le brin le plus proche et utilise la direction LOCALE de l''axe pour '
  'rester juste sur les tracés sinueux. Pendant électrique du parterre pair '
  'et impair.';


-- ============================================================================
-- ÉTAPE 5.1 — DÉCOUPAGE DES SECTIONS PAR geom_sol DE LA LIGNE
-- ----------------------------------------------------------------------------
-- ST_Split scinde chaque section avec l'axe exact qui a servi à construire son
-- emprise. On évite ainsi d'utiliser le corridor fusionné, qui pouvait associer
-- une section à plusieurs axes parallèles ou ramifiés.
-- ============================================================================

INSERT INTO uti.t2h_elec_emplacements (
    id_treevans, id_section, id_ligne, orientation,
    accessible_prop, surface_m2, perimetre_m, geom
)
WITH base AS (
    SELECT
        s.id_section,
        s.id_ligne,
        s.regime_foncier,
        ST_MakeValid(s.geom) AS geom_section,
        l.geom_sol           AS geom_axe
    FROM uti.t2h_elec_sections s
    JOIN uti.t2h_elec_lignes l
      ON l.id_ligne = s.id_ligne
    WHERE l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
),
scinde AS (
    SELECT
        b.id_section,
        b.id_ligne,
        b.regime_foncier,
        b.geom_axe,
        (
            ST_Dump(
                CASE
                    WHEN ST_Intersects(b.geom_section, b.geom_axe) THEN
                        ST_Split(
                            b.geom_section,
                            ST_Node(ST_UnaryUnion(b.geom_axe))
                        )
                    ELSE b.geom_section
                END
            )
        ).geom AS geom_part
    FROM base b
),
valides AS (
    SELECT
        sc.id_section,
        sc.id_ligne,
        sc.regime_foncier,
        sc.geom_axe,
        ST_Multi(sc.geom_part)::geometry(MultiPolygon, 2950) AS geom_part
    FROM scinde sc
    WHERE sc.geom_part IS NOT NULL
      AND GeometryType(sc.geom_part) IN ('POLYGON', 'MULTIPOLYGON')
      AND ST_Area(sc.geom_part) > 1
),
oriente AS (
    SELECT
        v.*,
        uti.f_cote_axe(v.geom_part, v.geom_axe) AS orientation
    FROM valides v
)
SELECT
    'TVS-ELEC-EMPL-' || LPAD(
        ROW_NUMBER() OVER (
            ORDER BY o.id_section, o.orientation, ST_Area(o.geom_part)
        )::text,
        6,
        '0'
    ),
    o.id_section,
    o.id_ligne,
    o.orientation,
    (o.regime_foncier <> 'PRIVE'),
    ROUND(ST_Area(o.geom_part)::numeric, 2),
    ROUND(ST_Perimeter(o.geom_part)::numeric, 2),
    o.geom_part
FROM oriente o;


-- ============================================================================
-- ÉTAPE 5.2 — ACTIVITÉ (infrastructures internes au corridor)
-- ----------------------------------------------------------------------------
-- « Des sections peuvent abriter des infrastructures (piste cyclable, sentier).
--   Ces infrastructures constituent des empreintes pour matérialiser les
--   emplacements. »
-- ============================================================================

DO $activite$
DECLARE
    n integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'raw' AND table_name = 'reseau_cyclable') THEN
        RAISE NOTICE '[INFO] raw.reseau_cyclable absente — activité non renseignée.';
        RETURN;
    END IF;

    UPDATE uti.t2h_elec_emplacements em
    SET activite = 'PISTE_CYCLABLE',
        activite_autorisee = true
    WHERE EXISTS (
        SELECT 1 FROM raw.reseau_cyclable rc
        WHERE ST_Intersects(em.geom, rc.geometry)
    );

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '[OK] Emplacements avec piste cyclable : %', n;
END
$activite$;


-- ============================================================================
-- ÉTAPE 5.3 — CLÉ DE RECHERCHE
-- ----------------------------------------------------------------------------
-- « Ces adresses doivent constituer le repère géographique de la recherche. »
-- ============================================================================

UPDATE uti.t2h_elec_emplacements em
SET recherche = concat_ws(' ',
        em.id_treevans, 'emplacement', em.orientation, em.activite,
        s.zonage_affectation, s.regime_foncier, s.arrondissement)
FROM uti.t2h_elec_sections s
WHERE s.id_section = em.id_section;


-- ============================================================================
-- ÉTAPE 6 — RELATIONS DE COHABITATION AVEC LES LOTS RIVERAINS
-- ----------------------------------------------------------------------------
-- Pour chaque lot rencontrant un emplacement, on calcule la part de sa surface
-- couverte. C'est ce qui permet au propriétaire de voir la portion de son lot
-- qui lui échappe, et au gestionnaire de voir les espaces de sécurité situés
-- sur des propriétés privées.
--
-- Le rattachement se fait à l'EMPLACEMENT — niveau le plus fin — et remonte à
-- la section par héritage.
--
--   INCLUS      le lot est entièrement dans l'emplacement
--   GREVE       une part substantielle du lot est couverte
--   CHEVAUCHANT une part mineure est couverte
-- ============================================================================

INSERT INTO uti.t2h_elec_rel_lots (
    id_emplacement, id_section, id_lot, code_utili, libelle_ut, type_relation,
    surface_lot_m2, surface_grevee_m2, part_grevee_pct,
    proprietaire_type, active, geom_intersection
)
WITH croisement AS (
    SELECT
        em.id_emplacement,
        em.id_section,
        f.id_uev                  AS id_lot,
        f.code_utili,
        f.libelle_ut,
        ST_Area(f.geometry)       AS surf_lot,
        ST_Multi(ST_CollectionExtract(
            ST_Intersection(em.geom, ST_MakeValid(f.geometry)), 3)) AS geom_inter
    FROM uti.t2h_elec_emplacements em
    JOIN raw.role_foncier f
      ON ST_Intersects(em.geom, f.geometry)
),
mesure AS (
    SELECT c.*, ST_Area(c.geom_inter) AS surf_grevee
    FROM croisement c
    WHERE c.geom_inter IS NOT NULL
      AND NOT ST_IsEmpty(c.geom_inter)
      AND ST_Area(c.geom_inter) > 0.5
)
SELECT
    m.id_emplacement,
    m.id_section,
    m.id_lot,
    m.code_utili,
    m.libelle_ut,
    CASE
        WHEN m.surf_grevee / NULLIF(m.surf_lot, 0) >= 0.99 THEN 'INCLUS'
        WHEN m.surf_grevee / NULLIF(m.surf_lot, 0) >= 0.20 THEN 'GREVE'
        ELSE 'CHEVAUCHANT'
    END,
    ROUND(m.surf_lot::numeric, 2),
    ROUND(m.surf_grevee::numeric, 2),
    ROUND((100.0 * m.surf_grevee / NULLIF(m.surf_lot, 0))::numeric, 2),
    uti.f_regime_foncier(m.code_utili),
    true,
    m.geom_inter
FROM mesure m;


-- ============================================================================
-- BILAN
-- ============================================================================

DO $bilan$
DECLARE
    n_sec    integer;
    n_lignes integer;
    n_empl   integer;
    n_gauche integer;
    n_droite integer;
    n_axiale integer;
    n_rel    integer;
    n_greve  integer;
    n_prive  integer;
BEGIN
    SELECT count(*) INTO n_sec FROM uti.t2h_elec_sections;
    SELECT count(DISTINCT id_ligne) INTO n_lignes
    FROM uti.t2h_elec_emplacements
    WHERE id_ligne IS NOT NULL;
    SELECT count(*) INTO n_empl FROM uti.t2h_elec_emplacements;
    SELECT count(*) INTO n_gauche FROM uti.t2h_elec_emplacements WHERE orientation = 'GAUCHE';
    SELECT count(*) INTO n_droite FROM uti.t2h_elec_emplacements WHERE orientation = 'DROITE';
    SELECT count(*) INTO n_axiale FROM uti.t2h_elec_emplacements WHERE orientation = 'AXIALE';
    SELECT count(*) INTO n_rel    FROM uti.t2h_elec_rel_lots;
    SELECT count(*) INTO n_greve  FROM uti.t2h_elec_rel_lots
        WHERE type_relation IN ('INCLUS', 'GREVE');
    SELECT count(*) INTO n_prive  FROM uti.t2h_elec_rel_lots
        WHERE proprietaire_type = 'PRIVE' AND type_relation IN ('INCLUS', 'GREVE');

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE '  sections            : %', n_sec;
    RAISE NOTICE '  lignes représentées : %', n_lignes;
    RAISE NOTICE '  emplacements        : %  (ratio %)',
                 n_empl, ROUND((n_empl::numeric / NULLIF(n_sec, 0)), 2);
    RAISE NOTICE '    GAUCHE            : %', n_gauche;
    RAISE NOTICE '    DROITE            : %', n_droite;
    RAISE NOTICE '    AXIALE            : %', n_axiale;
    RAISE NOTICE '  relations aux lots  : %', n_rel;
    RAISE NOTICE '    lots grevés       : %', n_greve;
    RAISE NOTICE '    dont PRIVÉS       : %  <- profil Propriétaire', n_prive;
    RAISE NOTICE '--------------------------------------------------';

    IF n_empl > 0 THEN
        DELETE FROM uti.t2h_elec_journal_blocages
        WHERE etape = 'EMPLACEMENTS' AND severite = 'BLOQUANT';
    END IF;

    -- Un ratio proche de 1 signalerait que le découpage n'a pas opéré
    IF n_sec > 0 AND n_empl::numeric / n_sec < 1.3 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        SELECT 'EMPLACEMENTS', 'AVERTISSEMENT',
               format('Le ratio emplacements sur sections vaut %s. Un découpage '
                      'effectif de part et d''autre de l''axe devrait approcher 2. '
                      'Les axes geom_sol ne traversent probablement pas les '
                      'sections de bout en bout.',
                      ROUND((n_empl::numeric / n_sec), 2)),
               'Vérifier geom_sol des lignes par rapport aux sections.'
        WHERE NOT EXISTS (
            SELECT 1 FROM uti.t2h_elec_journal_blocages
            WHERE etape = 'EMPLACEMENTS' AND severite = 'AVERTISSEMENT');
    END IF;
END
$bilan$;


-- ============================================================================
-- VUES PAR PROFIL UTILISATEUR
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_t2h_elec_profil_proprietaire AS
SELECT
    r.id_lot,
    r.libelle_ut                      AS usage_lot,
    r.type_relation,
    r.surface_lot_m2,
    r.surface_grevee_m2,
    r.part_grevee_pct,
    s.zonage_affectation,
    s.arrondissement,
    em.orientation,
    em.accessible_prop,
    r.geom_intersection               AS geom
FROM uti.t2h_elec_rel_lots r
LEFT JOIN uti.t2h_elec_sections     s  ON s.id_section     = r.id_section
LEFT JOIN uti.t2h_elec_emplacements em ON em.id_emplacement = r.id_emplacement
WHERE r.proprietaire_type = 'PRIVE'
  AND r.active
ORDER BY r.part_grevee_pct DESC;

COMMENT ON VIEW uti.v_t2h_elec_profil_proprietaire IS
  'Profil Propriétaire — parts de lots privés grevées par une emprise.';


CREATE OR REPLACE VIEW uti.v_t2h_elec_profil_gestionnaire AS
SELECT
    s.arrondissement,
    s.zonage_affectation,
    count(DISTINCT s.id_section)                    AS nb_sections,
    count(DISTINCT r.id_lot) FILTER
        (WHERE r.proprietaire_type = 'PRIVE')       AS nb_lots_prives,
    ROUND(sum(r.surface_grevee_m2) FILTER
        (WHERE r.proprietaire_type = 'PRIVE') / 10000.0, 2) AS ha_prives_greves,
    ROUND(sum(s.surface_m2) / 10000.0, 2)           AS ha_emprise_total
FROM uti.t2h_elec_sections s
LEFT JOIN uti.t2h_elec_rel_lots r ON r.id_section = s.id_section AND r.active
GROUP BY s.arrondissement, s.zonage_affectation
ORDER BY ha_prives_greves DESC NULLS LAST;

COMMENT ON VIEW uti.v_t2h_elec_profil_gestionnaire IS
  'Profil Gestionnaire — espaces de sécurité par arrondissement et affectation, '
  'avec la part située sur propriété privée.';