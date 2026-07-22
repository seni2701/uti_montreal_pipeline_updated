-- ============================================================================
-- 20b_utg.sql   —   UNITÉS TERRITORIALES DE GESTION
-- ----------------------------------------------------------------------------
-- Le mandat impose de rattacher chaque traitement au bon niveau :
--     emplacement -> tronçon -> UTI -> UTG
--
-- Or la colonne id_utg existait dans toutes les tables sans jamais être
-- alimentée. Ce fichier crée le référentiel UTG et le propage.
--
-- UTG-A (ADMINISTRATIVE) : découpage politique — arrondissements de la Ville de
--   Montréal et municipalités reconstituées de l'agglomération. C'est le
--   découpage retenu ici, dérivé de raw.limites_admin.
--
-- UTG-O (OPÉRATIONNELLE) : découpage d'exploitation, qui ne coïncide pas
--   nécessairement avec l'administratif. Aucune source ne le décrit dans le
--   corpus — la colonne type_utg est prête à l'accueillir.
--
-- RÈGLE D'AFFECTATION selon le niveau :
--   EMPLACEMENT, SECTION  -> UTG contenant le centroïde, valeur UNIQUE
--   EMPRISE               -> UTG dominante en surface
--   CORRIDOR, LIGNE       -> UTG dominante en longueur
--   PYLONE, POSTE         -> UTG contenant l'empreinte
--
-- Une entité qui chevauche plusieurs UTG reçoit la dominante. Le champ
-- arrondissement conserve, lui, la liste complète — les deux se complètent.
--
-- PRÉREQUIS : 19_sections.sql, 20_emplacements.sql
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 20b
-- ============================================================================

-- ============================================================================
-- 1 — RÉFÉRENTIEL UTG
-- ============================================================================

-- Nécessaire pour comparer les noms sans dépendre des accents ni de l'encodage
CREATE EXTENSION IF NOT EXISTS unaccent;

DROP TABLE IF EXISTS uti.utg CASCADE;

CREATE TABLE uti.utg (
    id_utg          text PRIMARY KEY,
    type_utg        text NOT NULL DEFAULT 'UTG-A'
                    CHECK (type_utg IN ('UTG-A', 'UTG-O')),
    nom_utg         text NOT NULL,
    statut_municipal text,
    surface_m2      numeric(16,2),
    geom            geometry(MultiPolygon, 2950) NOT NULL,
    date_maj        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.utg IS
  'Unités Territoriales de Gestion. UTG-A est le découpage administratif — '
  'arrondissements et villes liées. UTG-O, le découpage opérationnel, n''est '
  'décrit par aucune source du corpus et reste à alimenter.';

COMMENT ON COLUMN uti.utg.statut_municipal IS
  'ARRONDISSEMENT pour la Ville de Montréal, VILLE_LIEE pour une des 15 '
  'municipalités reconstituées de l''agglomération. Distinction déterminante — '
  'le PUM 2050 ne couvre QUE les arrondissements, chaque ville liée ayant son '
  'propre plan d''urbanisme. Liste explicite plutôt que déduction géométrique, '
  'un simple contact de frontière avec le PUM ne prouvant pas la couverture.';

CREATE INDEX idx_utg_geom ON uti.utg USING GIST (geom);


DO $ref_utg$
DECLARE
    col_nom text;
    n       integer;
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
        RAISE NOTICE '[AVERT] colonne de nom introuvable dans raw.limites_admin.';
        RETURN;
    END IF;

    EXECUTE format($fmt$
        INSERT INTO uti.utg (id_utg, type_utg, nom_utg, statut_municipal,
                             surface_m2, geom)
        SELECT
            'TVS-UTG-A-' || LPAD(ROW_NUMBER() OVER (ORDER BY a.%1$I)::text, 3, '0'),
            'UTG-A',
            a.%1$I::text,
            CASE
                WHEN unaccent(lower(a.%1$I::text)) IN (
                    'baie-d''urfe', 'beaconsfield', 'cote-saint-luc',
                    'dollard-des-ormeaux', 'dorval', 'hampstead', 'kirkland',
                    'l''ile-dorval', 'ile-dorval', 'montreal-est',
                    'montreal-ouest', 'mont-royal', 'pointe-claire',
                    'sainte-anne-de-bellevue', 'senneville', 'westmount'
                ) THEN 'VILLE_LIEE'
                ELSE 'ARRONDISSEMENT'
            END,
            ROUND(ST_Area(a.geometry)::numeric, 2),
            ST_Multi(ST_MakeValid(a.geometry))::geometry(MultiPolygon, 2950)
        FROM raw.limites_admin a
        WHERE a.geometry IS NOT NULL
    $fmt$, col_nom);

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '[OK] Référentiel UTG-A : % unités', n;
END
$ref_utg$;


-- ============================================================================
-- 2 — PROPAGATION aux niveaux ponctuels et surfaciques fins
-- ----------------------------------------------------------------------------
-- Le centroïde suffit : ces entités sont petites devant une UTG.
-- ============================================================================

UPDATE uti.t2h_elec_pylones p
SET id_utg = u.id_utg
FROM uti.utg u
WHERE u.type_utg = 'UTG-A'
  AND ST_Intersects(u.geom, ST_PointOnSurface(p.geom_polygone));

UPDATE uti.t2h_elec_postes po
SET id_utg = u.id_utg
FROM uti.utg u
WHERE u.type_utg = 'UTG-A'
  AND ST_Intersects(u.geom, ST_PointOnSurface(po.geom));

UPDATE uti.t2h_elec_sections s
SET id_utg = u.id_utg
FROM uti.utg u
WHERE u.type_utg = 'UTG-A'
  AND ST_Intersects(u.geom, ST_PointOnSurface(s.geom));


-- ============================================================================
-- 3 — PROPAGATION aux emprises (UTG dominante en surface)
-- ============================================================================

WITH dominante AS (
    SELECT DISTINCT ON (e.id_emprise)
        e.id_emprise,
        u.id_utg
    FROM uti.t2h_elec_emprises e
    JOIN uti.utg u
      ON u.type_utg = 'UTG-A'
     AND ST_Intersects(e.geom, u.geom)
    ORDER BY e.id_emprise,
             ST_Area(ST_Intersection(e.geom, u.geom)) DESC
)
UPDATE uti.t2h_elec_emprises e
SET id_utg = d.id_utg
FROM dominante d
WHERE d.id_emprise = e.id_emprise;


-- ============================================================================
-- 4 — PROPAGATION aux corridors et lignes (UTG dominante en longueur)
-- ============================================================================

WITH dominante AS (
    SELECT DISTINCT ON (c.id_corridor)
        c.id_corridor,
        u.id_utg
    FROM uti.t2h_elec_corridors c
    JOIN uti.utg u
      ON u.type_utg = 'UTG-A'
     AND ST_Intersects(c.geom, u.geom)
    ORDER BY c.id_corridor,
             ST_Length(ST_Intersection(c.geom, u.geom)) DESC
)
UPDATE uti.t2h_elec_corridors c
SET id_utg = d.id_utg
FROM dominante d
WHERE d.id_corridor = c.id_corridor;

WITH dominante AS (
    SELECT DISTINCT ON (l.id_ligne)
        l.id_ligne,
        u.id_utg
    FROM uti.t2h_elec_lignes l
    JOIN uti.utg u
      ON u.type_utg = 'UTG-A'
     AND ST_Intersects(l.geom, u.geom)
    ORDER BY l.id_ligne,
             ST_Length(ST_Intersection(l.geom, u.geom)) DESC
)
UPDATE uti.t2h_elec_lignes l
SET id_utg = d.id_utg
FROM dominante d
WHERE d.id_ligne = l.id_ligne;


-- ============================================================================
-- 5 — CONTRÔLE
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_t2h_elec_bilan_utg AS
SELECT
    u.id_utg,
    u.nom_utg,
    u.statut_municipal,
    count(DISTINCT c.id_corridor)                   AS nb_corridors,
    count(DISTINCT p.id_pylone)                     AS nb_pylones,
    count(DISTINCT s.id_section)                    AS nb_sections,
    COALESCE(ROUND(sum(DISTINCT s.surface_m2) / 10000.0, 2), 0) AS ha_sections
FROM uti.utg u
LEFT JOIN uti.t2h_elec_corridors c ON c.id_utg = u.id_utg
LEFT JOIN uti.t2h_elec_pylones   p ON p.id_utg = u.id_utg
LEFT JOIN uti.t2h_elec_sections  s ON s.id_utg = u.id_utg
WHERE u.type_utg = 'UTG-A'
GROUP BY u.id_utg, u.nom_utg, u.statut_municipal
HAVING count(DISTINCT c.id_corridor) > 0
    OR count(DISTINCT p.id_pylone) > 0
    OR count(DISTINCT s.id_section) > 0
ORDER BY nb_sections DESC, nb_pylones DESC;

COMMENT ON VIEW uti.v_t2h_elec_bilan_utg IS
  'Répartition du réseau T2H par UTG administrative. Seules les UTG réellement '
  'traversées apparaissent.';


DO $bilan$
DECLARE
    n_utg   integer;
    n_liees integer;
    n_pyl   integer;
    n_sec   integer;
    n_cor   integer;
BEGIN
    SELECT count(*) INTO n_utg   FROM uti.utg WHERE type_utg = 'UTG-A';
    SELECT count(*) INTO n_liees FROM uti.utg WHERE statut_municipal = 'VILLE_LIEE';
    SELECT count(*) INTO n_pyl   FROM uti.t2h_elec_pylones   WHERE id_utg IS NOT NULL;
    SELECT count(*) INTO n_sec   FROM uti.t2h_elec_sections  WHERE id_utg IS NOT NULL;
    SELECT count(*) INTO n_cor   FROM uti.t2h_elec_corridors WHERE id_utg IS NOT NULL;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE '  UTG-A référencées   : %  (dont % villes liées)', n_utg, n_liees;
    RAISE NOTICE '  corridors rattachés : %', n_cor;
    RAISE NOTICE '  pylônes rattachés   : %', n_pyl;
    RAISE NOTICE '  sections rattachées : %', n_sec;
    RAISE NOTICE '--------------------------------------------------';

    INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
    SELECT 'UTG', 'INFO',
           'Seule l''UTG-A (administrative) est alimentée, dérivée des limites '
           'municipales. L''UTG-O (opérationnelle) n''est décrite par aucune '
           'source du corpus.',
           'Obtenir de Treevans le découpage opérationnel s''il diffère de '
           'l''administratif, puis alimenter uti.utg avec type_utg = UTG-O.'
    WHERE NOT EXISTS (
        SELECT 1 FROM uti.t2h_elec_journal_blocages WHERE etape = 'UTG');
END
$bilan$;