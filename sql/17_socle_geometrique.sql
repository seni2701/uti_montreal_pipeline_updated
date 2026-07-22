-- ============================================================================
-- 17_socle_geometrique.sql   —   LIGNES, PYLÔNES, CORRIDORS, TENSION, POSTES
-- ----------------------------------------------------------------------------
-- Étape 1 du mandat : matérialisation de l'infrastructure de référence.
--
-- PRÉREQUIS : 01b_load_energie.py, 01c_load_zonage_foncier.py,
--             raw.elec_lignes_osm_montreal (tension)
--
-- PRODUIT :
--   uti.t2h_elec_lignes     <- raw.elec_axe_transport
--                              avec geom_sol = projection 2D au sol
--   uti.t2h_elec_pylones    <- raw.elec_pylones  (POLYGONES)
--   uti.t2h_elec_corridors  <- regroupement des lignes en composantes connexes
--   tension                 <- recoupement OpenStreetMap
--   uti.t2h_elec_postes     <- déduction topologique
--
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 17
-- ============================================================================

TRUNCATE TABLE uti.t2h_elec_postes    RESTART IDENTITY CASCADE;
TRUNCATE TABLE uti.t2h_elec_pylones   RESTART IDENTITY CASCADE;
TRUNCATE TABLE uti.t2h_elec_lignes    RESTART IDENTITY CASCADE;
TRUNCATE TABLE uti.t2h_elec_corridors RESTART IDENTITY CASCADE;


-- ============================================================================
-- AJOUT DE TRAÇABILITÉ — PROJECTION DES LIGNES AU SOL
-- ----------------------------------------------------------------------------
-- geom_source conserve la géométrie normalisée dans le SCR de travail.
-- geom_sol est l'axe 2D utilisé pour tous les buffers, sections et emplacements.
-- ST_Force2D retire toute altitude éventuelle : la ligne aérienne est ainsi
-- représentée par sa projection cartographique au sol, sans inventer de largeur.
-- ============================================================================

ALTER TABLE uti.t2h_elec_lignes
    ADD COLUMN IF NOT EXISTS geom_sol geometry(MultiLineString, 2950);

CREATE INDEX IF NOT EXISTS idx_t2h_elec_lignes_geom_sol
    ON uti.t2h_elec_lignes USING GIST (geom_sol);


-- ============================================================================
-- 1 — LIGNES PROJETÉES AU SOL
-- ============================================================================

WITH source_normalisee AS (
    SELECT
        r.id,
        ST_Multi(
            ST_CollectionExtract(
                ST_MakeValid(
                    CASE
                        WHEN ST_SRID(r.geometry) = 2950
                            THEN ST_Force2D(r.geometry)
                        WHEN ST_SRID(r.geometry) = 0
                            THEN ST_SetSRID(ST_Force2D(r.geometry), 2950)
                        ELSE ST_Transform(ST_Force2D(r.geometry), 2950)
                    END
                ),
                2
            )
        )::geometry(MultiLineString, 2950) AS geom_sol
    FROM raw.elec_axe_transport r
    WHERE r.geometry IS NOT NULL
      AND NOT ST_IsEmpty(r.geometry)
),
valides AS (
    SELECT id, geom_sol
    FROM source_normalisee
    WHERE geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(geom_sol)
      AND ST_Length(geom_sol) > 0
)
INSERT INTO uti.t2h_elec_lignes (
    id_treevans, id_source, source_donnee, reseau,
    exploitant, longueur_m, geom, geom_source, geom_sol
)
SELECT
    'TVS-ELEC-LGN-' || LPAD(ROW_NUMBER() OVER (ORDER BY v.id)::text, 6, '0'),
    v.id::text,
    'VMTL_2020',
    'TRANSPORT',
    'Hydro-Québec',
    ROUND(ST_Length(v.geom_sol)::numeric, 2),
    v.geom_sol,
    v.geom_sol,
    v.geom_sol
FROM valides v;


-- ============================================================================
-- 2 — PYLÔNES (empreinte au sol polygonale)
-- ----------------------------------------------------------------------------
-- empreinte_fiable = false sous 1 m2 : ce sont des symboles de taille fixe,
-- pas des relevés photogrammétriques.
-- candidat_poste = true au-delà de 300 m2 : trop vaste pour une base de pylône.
-- ============================================================================

INSERT INTO uti.t2h_elec_pylones (
    id_treevans, id_source, source_donnee, type_support,
    geom_polygone, geom, surface_m2, empreinte_fiable, candidat_poste
)
SELECT
    'TVS-ELEC-PYL-' || LPAD(ROW_NUMBER() OVER (ORDER BY r.id)::text, 6, '0'),
    r.id::text,
    'VMTL_2020',
    'BASE_BETON',
    ST_Multi(ST_Force2D(ST_MakeValid(r.geometry)))::geometry(MultiPolygon, 2950),
    ST_PointOnSurface(ST_MakeValid(r.geometry))::geometry(Point, 2950),
    ROUND(ST_Area(r.geometry)::numeric, 2),
    (ST_Area(r.geometry) >= 1.0),
    (ST_Area(r.geometry) > 300.0)
FROM raw.elec_pylones r
WHERE r.geometry IS NOT NULL AND NOT ST_IsEmpty(r.geometry);


-- ============================================================================
-- 3 — CORRIDORS (composantes connexes, tolérance 1 m)
-- ----------------------------------------------------------------------------
-- ST_Union fusionne réellement, contrairement à ST_Collect qui empile et
-- produit une GeometryCollection incompatible avec MultiLineString.
-- ============================================================================

INSERT INTO uti.t2h_elec_corridors (
    id_treevans, reseau, nb_lignes,
    longueur_axe_m, longueur_cumulee_m, geom, geom_enveloppe
)
WITH clusters AS (
    SELECT id_ligne, geom_sol AS geom, longueur_m,
           ST_ClusterDBSCAN(geom_sol, eps := 1.0, minpoints := 1) OVER () AS cid
    FROM uti.t2h_elec_lignes
    WHERE geom_sol IS NOT NULL
),
agreges AS (
    SELECT
        cid,
        count(*)        AS nb_lignes,
        sum(longueur_m) AS longueur_cumulee_m,
        ST_Multi(ST_CollectionExtract(ST_LineMerge(ST_Union(geom)), 2)) AS geom_fusion,
        ST_ConvexHull(ST_Collect(geom)) AS enveloppe
    FROM clusters
    GROUP BY cid
)
SELECT
    'TVS-ELEC-COR-' || LPAD(ROW_NUMBER() OVER (ORDER BY cid)::text, 4, '0'),
    'TRANSPORT',
    a.nb_lignes,
    ROUND(ST_Length(a.geom_fusion)::numeric, 2),
    ROUND(a.longueur_cumulee_m, 2),
    a.geom_fusion::geometry(MultiLineString, 2950),
    CASE WHEN ST_GeometryType(a.enveloppe) = 'ST_Polygon'
         THEN a.enveloppe::geometry(Polygon, 2950) ELSE NULL END
FROM agreges a
WHERE a.geom_fusion IS NOT NULL AND NOT ST_IsEmpty(a.geom_fusion);


-- ============================================================================
-- 4 — RATTACHEMENTS AU CORRIDOR
-- ----------------------------------------------------------------------------
-- LATERAL ne peut référencer la cible d'un UPDATE en PostgreSQL. On résout
-- dans une CTE puis on joint sur la clé primaire.
-- ============================================================================

WITH r AS (
    SELECT l.id_ligne, v.id_corridor
    FROM uti.t2h_elec_lignes l
    CROSS JOIN LATERAL (
        SELECT c.id_corridor FROM uti.t2h_elec_corridors c
        ORDER BY l.geom_sol <-> c.geom LIMIT 1
    ) v
)
UPDATE uti.t2h_elec_lignes l
SET id_corridor = r.id_corridor
FROM r WHERE r.id_ligne = l.id_ligne;


WITH r AS (
    SELECT p.id_pylone, v.id_corridor, v.d
    FROM uti.t2h_elec_pylones p
    CROSS JOIN LATERAL (
        SELECT c.id_corridor, ST_Distance(p.geom, c.geom) AS d
        FROM uti.t2h_elec_corridors c
        ORDER BY p.geom <-> c.geom LIMIT 1
    ) v
)
UPDATE uti.t2h_elec_pylones p
SET id_corridor = r.id_corridor
FROM r WHERE r.id_pylone = p.id_pylone AND r.d <= 50.0;


-- Rattachement indicatif à la ligne la plus proche (artefact assumé)
WITH r AS (
    SELECT p.id_pylone, v.id_ligne, v.d
    FROM uti.t2h_elec_pylones p
    CROSS JOIN LATERAL (
        SELECT l.id_ligne, ST_Distance(p.geom, l.geom_sol) AS d
        FROM uti.t2h_elec_lignes l
        ORDER BY p.geom <-> l.geom_sol LIMIT 1
    ) v
)
UPDATE uti.t2h_elec_pylones p
SET id_ligne = r.id_ligne
FROM r WHERE r.id_pylone = p.id_pylone AND r.d <= 50.0;


-- ============================================================================
-- 5 — TENSION par recoupement OpenStreetMap
-- ----------------------------------------------------------------------------
-- La source OSM est en EPSG:4326. Reprojection préalable indispensable :
-- un ST_DWithin en degrés sur des données métriques ne retourne rien.
--
-- Règle pour les lignes bordées de plusieurs tensions : on retient LA PLUS
-- HAUTE. Choix prudent, l'emprise d'une classe supérieure couvre l'inférieure.
-- ============================================================================

DO $tension$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'raw'
                     AND table_name = 'elec_lignes_osm_montreal') THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        VALUES ('TENSION', 'BLOQUANT',
                'Couche raw.elec_lignes_osm_montreal absente. Aucune tension ne peut '
                'être attribuée, donc aucune largeur d''emprise par palier.',
                'Charger un export OpenStreetMap des lignes électriques de Montréal '
                'avec le tag voltage, ou obtenir la tension auprès d''Hydro-Québec.');
        RAISE NOTICE '[BLOQUANT] couche OSM absente — tension non attribuable.';
        RETURN;
    END IF;

    -- Reprojection si nécessaire
    EXECUTE 'ALTER TABLE raw.elec_lignes_osm_montreal
             ADD COLUMN IF NOT EXISTS geom_2950 geometry(Geometry, 2950)';
    EXECUTE 'UPDATE raw.elec_lignes_osm_montreal
             SET geom_2950 = ST_Transform(ST_SetSRID(geom, 4326), 2950)
             WHERE geom IS NOT NULL AND geom_2950 IS NULL';
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_osm_elec_geom_2950
             ON raw.elec_lignes_osm_montreal USING GIST (geom_2950)';

    -- Attribution aux lignes
    WITH t AS (
        SELECT
            l.id_ligne,
            max(uti.f_tension_num(o.tension_kv)) AS tension_kv,
            count(DISTINCT o.tension_kv)         AS nb_cand,
            string_agg(DISTINCT o.tension_kv, ' / ' ORDER BY o.tension_kv) AS libelles
        FROM uti.t2h_elec_lignes l
        JOIN raw.elec_lignes_osm_montreal o
          ON ST_DWithin(l.geom_sol, o.geom_2950, 20)
        WHERE o.tension_kv IS NOT NULL
          AND o.tension_kv <> 'Inconnue'
          AND uti.f_tension_num(o.tension_kv) IS NOT NULL
        GROUP BY l.id_ligne
    )
    UPDATE uti.t2h_elec_lignes l
    SET tension_kv = t.tension_kv,
        tension_origine = CASE
            WHEN t.nb_cand = 1 THEN 'OSM_ODBL — univoque (' || t.libelles || ')'
            ELSE 'OSM_ODBL — ' || t.nb_cand || ' tensions voisines ('
                 || t.libelles || '), la plus haute retenue'
        END
    FROM t WHERE t.id_ligne = l.id_ligne;
END
$tension$;


-- Remontée au corridor : tension la plus haute de ses lignes
WITH t AS (
    SELECT id_corridor,
           max(tension_kv) AS tension_kv,
           count(*) FILTER (WHERE tension_origine LIKE '%plus haute%') AS n_ambigu
    FROM uti.t2h_elec_lignes
    WHERE id_corridor IS NOT NULL AND tension_kv IS NOT NULL
    GROUP BY id_corridor
)
UPDATE uti.t2h_elec_corridors c
SET tension_kv = t.tension_kv,
    tension_origine = CASE
        WHEN t.n_ambigu > 0 THEN 'OSM_ODBL — dont ' || t.n_ambigu || ' ligne(s) ambiguë(s)'
        ELSE 'OSM_ODBL'
    END
FROM t WHERE t.id_corridor = c.id_corridor;


-- ============================================================================
-- 6 — COMPTAGES ET CIRCUITS PARALLÈLES
-- ============================================================================

WITH cpt AS (
    SELECT id_corridor, count(*) AS n FROM uti.t2h_elec_pylones
    WHERE id_corridor IS NOT NULL GROUP BY id_corridor
)
UPDATE uti.t2h_elec_corridors c SET nb_pylones = cpt.n
FROM cpt WHERE cpt.id_corridor = c.id_corridor;

UPDATE uti.t2h_elec_corridors SET nb_pylones = 0 WHERE nb_pylones IS NULL;


WITH p AS (
    SELECT a.id_corridor, count(*) AS n
    FROM uti.t2h_elec_lignes a
    JOIN uti.t2h_elec_lignes b
      ON a.id_ligne < b.id_ligne
     AND a.id_corridor = b.id_corridor
     AND ST_DWithin(a.geom_sol, b.geom_sol, 5.0)
     AND ST_Length(ST_Intersection(ST_Buffer(a.geom_sol, 5), b.geom_sol)) > 50
    GROUP BY a.id_corridor
)
UPDATE uti.t2h_elec_corridors c SET nb_circuits_paralleles = p.n
FROM p WHERE p.id_corridor = c.id_corridor;

UPDATE uti.t2h_elec_corridors
SET nb_circuits_paralleles = 0 WHERE nb_circuits_paralleles IS NULL;


-- ============================================================================
-- 7 — ARRONDISSEMENTS (introspection dynamique du nom de colonne)
-- ============================================================================

DO $arr$
DECLARE col_arr text;
BEGIN
    SELECT column_name INTO col_arr
    FROM information_schema.columns
    WHERE table_schema = 'raw' AND table_name = 'limites_admin'
      AND lower(column_name) IN ('nom_arr','nom_officiel','arrondissement',
            'nom_arrond','nom','municipalite','nom_mun','nom_ville','libelle')
    ORDER BY array_position(
        ARRAY['nom_arr','nom_officiel','arrondissement','nom_arrond','nom',
              'municipalite','nom_mun','nom_ville','libelle'], lower(column_name))
    LIMIT 1;

    IF col_arr IS NULL THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        VALUES ('ARRONDISSEMENT', 'AVERTISSEMENT',
                'Aucune colonne de nom d''arrondissement reconnue dans raw.limites_admin.',
                'Inspecter les colonnes réelles et compléter la liste du script 17.');
        RETURN;
    END IF;

    EXECUTE format($f$
        UPDATE uti.t2h_elec_lignes l SET arrondissement = s.noms
        FROM (SELECT l2.id_ligne,
                     string_agg(DISTINCT a.%1$I::text, ' | ' ORDER BY a.%1$I::text) AS noms
              FROM uti.t2h_elec_lignes l2
              JOIN raw.limites_admin a ON ST_Intersects(l2.geom_sol, a.geometry)
              GROUP BY l2.id_ligne) s
        WHERE s.id_ligne = l.id_ligne
    $f$, col_arr);

    EXECUTE format($f$
        UPDATE uti.t2h_elec_pylones p SET arrondissement = a.%1$I::text
        FROM raw.limites_admin a WHERE ST_Intersects(p.geom, a.geometry)
    $f$, col_arr);

    EXECUTE format($f$
        UPDATE uti.t2h_elec_corridors c SET arrondissement = s.noms
        FROM (SELECT c2.id_corridor,
                     string_agg(DISTINCT a.%1$I::text, ' | ' ORDER BY a.%1$I::text) AS noms
              FROM uti.t2h_elec_corridors c2
              JOIN raw.limites_admin a ON ST_Intersects(c2.geom, a.geometry)
              GROUP BY c2.id_corridor) s
        WHERE s.id_corridor = c.id_corridor
    $f$, col_arr);
END
$arr$;


-- ============================================================================
-- 8 — POSTES par déduction topologique
-- ----------------------------------------------------------------------------
-- Un pylône est TRAVERSÉ par les lignes, un poste est un TERMINUS. On retient
-- les empreintes de plus de 300 m2 sur lesquelles au moins deux circuits se
-- terminent. La surface seule ne discrimine pas : les plus vastes empreintes
-- sont des pylônes d'ancrage jumelés, pas des postes.
-- ============================================================================

INSERT INTO uti.t2h_elec_postes (
    id_treevans, id_pylone_source, source_donnee, tension_kv,
    nb_lignes_terminant, surface_m2, confirme, arrondissement, geom
)
WITH terminus AS (
    SELECT
        p.id_pylone,
        p.surface_m2,
        p.arrondissement,
        p.geom_polygone,
        c.tension_kv,
        (SELECT count(DISTINCT l.id_ligne)
         FROM uti.t2h_elec_lignes l, LATERAL ST_Dump(l.geom_sol) d
         WHERE ST_DWithin(ST_StartPoint(d.geom), p.geom_polygone, 30)
            OR ST_DWithin(ST_EndPoint(d.geom),   p.geom_polygone, 30)
        ) AS nb_term
    FROM uti.t2h_elec_pylones p
    LEFT JOIN uti.t2h_elec_corridors c ON c.id_corridor = p.id_corridor
    WHERE p.candidat_poste
)
SELECT
    'TVS-ELEC-PST-' || LPAD(ROW_NUMBER() OVER (ORDER BY t.id_pylone)::text, 4, '0'),
    t.id_pylone,
    'VMTL_2020_DEDUIT',
    t.tension_kv,
    t.nb_term,
    t.surface_m2,
    false,
    t.arrondissement,
    t.geom_polygone
FROM terminus t
WHERE t.nb_term >= 2;


-- ============================================================================
-- 9 — CONSIGNATION
-- ============================================================================

DO $bilan$
DECLARE
    n_lig integer; n_lig_sol integer; n_pyl integer; n_cor integer; n_pst integer;
    n_tens integer; n_par integer; n_sym integer; n_cand integer;
    km numeric;
BEGIN
    SELECT count(*) INTO n_lig FROM uti.t2h_elec_lignes;
    SELECT count(*) INTO n_lig_sol FROM uti.t2h_elec_lignes
        WHERE geom_sol IS NOT NULL AND NOT ST_IsEmpty(geom_sol);
    SELECT count(*) INTO n_pyl FROM uti.t2h_elec_pylones;
    SELECT count(*) INTO n_cor FROM uti.t2h_elec_corridors;
    SELECT count(*) INTO n_pst FROM uti.t2h_elec_postes;
    SELECT count(*) INTO n_tens FROM uti.t2h_elec_lignes WHERE tension_kv IS NOT NULL;
    SELECT coalesce(sum(nb_circuits_paralleles),0) INTO n_par FROM uti.t2h_elec_corridors;
    SELECT count(*) INTO n_sym FROM uti.t2h_elec_pylones WHERE NOT empreinte_fiable;
    SELECT count(*) INTO n_cand FROM uti.t2h_elec_pylones WHERE candidat_poste;
    SELECT ROUND(sum(longueur_axe_m)/1000.0, 1) INTO km FROM uti.t2h_elec_corridors;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE '  lignes             : %', n_lig;
    RAISE NOTICE '    projetées au sol : % / %', n_lig_sol, n_lig;
    RAISE NOTICE '  pylônes            : %  (dont % symboliques)', n_pyl, n_sym;
    RAISE NOTICE '  corridors          : %  (% km)', n_cor, km;
    RAISE NOTICE '  tension attribuée  : % / %', n_tens, n_lig;
    RAISE NOTICE '  circuits parallèles: % paires', n_par;
    RAISE NOTICE '  candidats postes   : %  -> % retenus (terminus)', n_cand, n_pst;
    RAISE NOTICE '--------------------------------------------------';

    DELETE FROM uti.t2h_elec_journal_blocages WHERE etape IN ('TENSION','PYLONES','POSTES','CORRIDORS');

    IF n_tens > 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        VALUES ('TENSION', 'AVERTISSEMENT',
                format('Tension attribuée à %s ligne(s) sur %s par recoupement '
                       'OpenStreetMap, licence ODbL et source contributive, NON par '
                       'Hydro-Québec.', n_tens, n_lig),
                'Faire valider les paliers par Hydro-Québec TransÉnergie avant tout '
                'usage réglementaire des emprises dérivées.');
    END IF;

    IF n_sym > 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        VALUES ('PYLONES', 'INFO',
                format('%s empreinte(s) de moins de 1 m2, toutes identiques. Symboles '
                       'de taille fixe et non relevés photogrammétriques. Marquées '
                       'empreinte_fiable = false.', n_sym),
                'Aucune action — signalement pour la note de limites.');
    END IF;

    IF n_pst > 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        VALUES ('POSTES', 'INFO',
                format('%s poste(s) déduit(s) par topologie sur %s candidat(s) : '
                       'empreinte de plus de 300 m2 avec au moins deux circuits qui '
                       's''y terminent. Aucune source ouverte ne fournit les postes '
                       'de Montréal.', n_pst, n_cand),
                'Confirmer par photo-interprétation sur orthophoto, puis passer '
                'confirme à true et renseigner nom_poste.');
    END IF;

    IF n_par > 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        VALUES ('CORRIDORS', 'AVERTISSEMENT',
                format('%s paire(s) de circuits parallèles. Le rattachement pylône '
                       'vers ligne est donc un ARTEFACT — la clé faisant foi est '
                       'id_corridor. Étendue réelle du réseau : %s km.', n_par, km),
                'Annoncer l''étendue réelle au client, jamais la somme cumulée des '
                'longueurs de lignes.');
    END IF;
END
$bilan$;


-- ============================================================================
-- VUES DE CONTRÔLE
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_t2h_bilan_corridor AS
SELECT c.id_corridor, c.id_treevans, c.arrondissement, c.tension_kv,
       c.nb_lignes, c.nb_pylones, c.nb_circuits_paralleles,
       ROUND(c.longueur_axe_m) AS longueur_m,
       g.demi_largeur_m, g.demi_largeur_m * 2 AS emprise_totale_m, g.statut
FROM uti.t2h_elec_corridors c
LEFT JOIN uti.t2h_elec_regles_degagement g
  ON g.reseau = c.reseau
 AND ((g.tension_kv_min IS NULL AND g.tension_kv_max IS NULL AND c.tension_kv IS NULL)
   OR c.tension_kv BETWEEN g.tension_kv_min AND g.tension_kv_max)
ORDER BY c.longueur_axe_m DESC;

CREATE OR REPLACE VIEW uti.v_t2h_tension_bilan AS
SELECT tension_kv, count(*) AS nb_lignes, ROUND(sum(longueur_m)) AS metres,
       count(*) FILTER (WHERE tension_origine LIKE '%plus haute%') AS dont_ambigues
FROM uti.t2h_elec_lignes
GROUP BY tension_kv ORDER BY tension_kv DESC NULLS LAST;

-- ============================================================================
-- FIN 17_socle_geometrique.sql
-- ============================================================================