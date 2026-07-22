-- ============================================================================
-- 22_incursions_interferences.sql   —   OCCUPATION ET INTERFÉRENCES
-- ----------------------------------------------------------------------------
-- Peuple les trois dernières tables de la chaîne T2H, qui portent des exigences
-- du mandat restées jusqu'ici sans traitement :
--
--   INCURSIONS       « Identification des incursions des lots ou UTI autres ou
--                      indépendants dans les réseaux des infrastructures. Le
--                      découpage des lots cadastraux peut se chevaucher ou
--                      s'encastrer dans la continuité de certaines
--                      infrastructures. » Cas d'exception à arbitrer.
--
--   INTERFERENCES    « Répertorier et représenter les données génératrices des
--                      informations sur les infrastructures urbaines et
--                      naturelles qui occupent ou interfèrent avec l'espace des
--                      tronçons des UTI. »
--
--   CONFLITS_VOIRIE  Croisements entre corridors électriques et tronçons
--                      routiers du Livrable A. Lien entre les deux familles.
--
-- ROBUSTESSE : chaque source est testée avant usage. Une couche absente produit
--   un INFO au journal, jamais une erreur.
--
-- PRÉREQUIS : 18_emprises.sql, 19_sections.sql, 20_emplacements.sql
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 22
-- ============================================================================

TRUNCATE TABLE uti.t2h_elec_incursions      RESTART IDENTITY;
TRUNCATE TABLE uti.t2h_elec_interferences   RESTART IDENTITY;
TRUNCATE TABLE uti.t2h_elec_conflits_voirie RESTART IDENTITY;


-- ============================================================================
-- 1 — INCURSIONS : lots cadastraux encastrés dans l'emprise aérienne
-- ----------------------------------------------------------------------------
-- ENCASTREMENT            lot entièrement contenu dans l'emprise
-- CHEVAUCHEMENT_CADASTRAL lot dont plus de la moitié est dans l'emprise
--
-- Le seuil de 50 pour cent écarte les simples riverains, qui relèvent de
-- t2h_elec_rel_lots, pour ne retenir que les vraies incursions.
-- ============================================================================

DO $incursions$
DECLARE
    n integer;
BEGIN
    IF (SELECT count(*) FROM uti.t2h_elec_emprises WHERE type_emprise = 'AERIENNE') = 0 THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        SELECT 'INCURSIONS', 'BLOQUANT',
               'Aucune emprise aérienne — les incursions se mesurent par rapport '
               'à l''emprise.',
               'Produire les emprises (18), puis relancer 22.'
        WHERE NOT EXISTS (
            SELECT 1 FROM uti.t2h_elec_journal_blocages
            WHERE etape = 'INCURSIONS' AND severite = 'BLOQUANT');
        RAISE NOTICE '[SOMMEIL] 0 emprise -> 0 incursion.';
        RETURN;
    END IF;

    INSERT INTO uti.t2h_elec_incursions (
        id_emprise, id_lot, type_incursion, surface_m2, traitement, geom
    )
    WITH croisement AS (
        SELECT
            e.id_emprise,
            f.id_uev                  AS id_lot,
            ST_Area(f.geometry)       AS surf_lot,
            ST_Multi(ST_CollectionExtract(
                ST_Intersection(e.geom, ST_MakeValid(f.geometry)), 3)) AS geom_inter
        FROM uti.t2h_elec_emprises e
        JOIN raw.role_foncier f
          ON ST_Intersects(e.geom, f.geometry)
        WHERE e.type_emprise = 'AERIENNE'
    ),
    mesure AS (
        SELECT
            c.*,
            ST_Area(c.geom_inter) AS surf_inter
        FROM croisement c
        WHERE c.geom_inter IS NOT NULL
          AND NOT ST_IsEmpty(c.geom_inter)
    )
    SELECT
        m.id_emprise,
        m.id_lot,
        CASE
            WHEN m.surf_inter / NULLIF(m.surf_lot, 0) >= 0.99 THEN 'ENCASTREMENT'
            ELSE 'CHEVAUCHEMENT_CADASTRAL'
        END,
        ROUND(m.surf_inter::numeric, 2),
        'A_ARBITRER',
        m.geom_inter
    FROM mesure m
    WHERE m.surf_inter / NULLIF(m.surf_lot, 0) >= 0.50;

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '[OK] Incursions cadastrales : %', n;

    IF n > 0 THEN
        DELETE FROM uti.t2h_elec_journal_blocages
        WHERE etape = 'INCURSIONS' AND severite = 'BLOQUANT';
    END IF;
END
$incursions$;


-- ============================================================================
-- 1b — INCURSIONS BÂTIES : empreintes de bâtiment dans l'emprise
-- ----------------------------------------------------------------------------
-- Un bâtiment sous une ligne de transport est une exception réglementaire.
-- Un nombre élevé signale plutôt une largeur d'emprise SURESTIMÉE — c'est un
-- contrôle indirect de la justesse des largeurs dérivées.
-- ============================================================================

DO $bati$
DECLARE
    n integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'raw' AND table_name = 'batiments') THEN
        RAISE NOTICE '[INFO] raw.batiments absente — incursions bâties non calculées.';
        RETURN;
    END IF;

    INSERT INTO uti.t2h_elec_incursions (
        id_emprise, id_lot, type_incursion, surface_m2, traitement, geom
    )
    SELECT
        e.id_emprise,
        NULL,
        'BATI_DANS_EMPRISE',
        ROUND(ST_Area(ST_Intersection(e.geom, ST_MakeValid(b.geometry)))::numeric, 2),
        'A_VERIFIER_ORTHOPHOTO',
        ST_Multi(ST_CollectionExtract(
            ST_Intersection(e.geom, ST_MakeValid(b.geometry)), 3))
    FROM uti.t2h_elec_emprises e
    JOIN raw.batiments b ON ST_Intersects(e.geom, b.geometry)
    WHERE e.type_emprise = 'AERIENNE'
      AND ST_Area(ST_Intersection(e.geom, ST_MakeValid(b.geometry))) > 5;

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '[OK] Incursions bâties : %', n;

    IF n > 20 THEN
        DELETE FROM uti.t2h_elec_journal_blocages
        WHERE etape = 'INCURSIONS' AND severite = 'AVERTISSEMENT';

        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        VALUES ('INCURSIONS', 'AVERTISSEMENT',
                format('%s empreinte(s) de bâtiment se trouvent dans une emprise '
                       'aérienne. Un bâtiment sous ligne de transport est une '
                       'exception réglementaire rare. Un nombre élevé indique '
                       'plutôt que la largeur d''emprise appliquée est trop large.',
                       n),
                'Vérifier quelques cas sur orthophoto. Si les bâtiments sont réels '
                'et hors emprise, les largeurs dérivées sont surestimées — argument '
                'concret pour obtenir le barème réel auprès d''Hydro-Québec.');
    END IF;
END
$bati$;


-- ============================================================================
-- 2 — INTERFÉRENCES : actifs naturels et infrastructurels dans les sections
-- ----------------------------------------------------------------------------
-- Rattachées à la SECTION (et non à l'emprise) : c'est le niveau auquel le
-- mandat demande de documenter ce qui occupe l'espace du tronçon.
-- ============================================================================

-- --- 2a. Arbres publics (composante naturelle) ------------------------------
DO $arbres$
DECLARE
    n integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'raw' AND table_name = 'arbres_publics') THEN
        RAISE NOTICE '[INFO] raw.arbres_publics absente.';
        RETURN;
    END IF;

    INSERT INTO uti.t2h_elec_interferences (
        id_section, famille, type_actif, id_actif_source,
        conforme_degagement, distance_axe_m, geom
    )
    SELECT
        s.id_section,
        'NATURELLE',
        'ARBRE',
        a.ctid::text,
        NULL,   -- la conformité exige la hauteur de l'arbre, absente de la source
        ROUND(ST_Distance(a.geometry, c.geom)::numeric, 2),
        a.geometry
    FROM uti.t2h_elec_sections s
    JOIN raw.arbres_publics a ON ST_Intersects(s.geom, a.geometry)
    LEFT JOIN uti.t2h_elec_corridors c ON c.id_corridor = s.id_corridor;

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '[OK] Interférences arbres : %', n;
END
$arbres$;


-- --- 2b. Réseau cyclable (composante infrastructurelle) ---------------------
DO $cyclable$
DECLARE
    n integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'raw' AND table_name = 'reseau_cyclable') THEN
        RAISE NOTICE '[INFO] raw.reseau_cyclable absente.';
        RETURN;
    END IF;

    INSERT INTO uti.t2h_elec_interferences (
        id_section, famille, type_actif, id_actif_source,
        conforme_degagement, geom
    )
    SELECT
        s.id_section,
        'INFRASTRUCTURELLE',
        'PISTE_CYCLABLE',
        c.ctid::text,
        true,   -- usage au sol compatible avec une emprise de transport
        ST_Multi(ST_CollectionExtract(ST_Intersection(s.geom, c.geometry), 2))
    FROM uti.t2h_elec_sections s
    JOIN raw.reseau_cyclable c ON ST_Intersects(s.geom, c.geometry);

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '[OK] Interférences pistes cyclables : %', n;
END
$cyclable$;


-- --- 2c. Bâtiments (composante infrastructurelle) ---------------------------
DO $bat_int$
DECLARE
    n integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'raw' AND table_name = 'batiments') THEN
        RETURN;
    END IF;

    INSERT INTO uti.t2h_elec_interferences (
        id_section, famille, type_actif, id_actif_source,
        conforme_degagement, geom
    )
    SELECT
        s.id_section,
        'INFRASTRUCTURELLE',
        'BATIMENT',
        b.ctid::text,
        false,  -- un bâtiment sous ligne n'est pas conforme au dégagement
        ST_Multi(ST_CollectionExtract(
            ST_Intersection(s.geom, ST_MakeValid(b.geometry)), 3))
    FROM uti.t2h_elec_sections s
    JOIN raw.batiments b ON ST_Intersects(s.geom, b.geometry)
    WHERE ST_Area(ST_Intersection(s.geom, ST_MakeValid(b.geometry))) > 5;

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '[OK] Interférences bâtiments : %', n;
END
$bat_int$;


-- ============================================================================
-- 3 — CONFLITS DE VOIRIE : corridors électriques x tronçons routiers
-- ----------------------------------------------------------------------------
-- SURPLOMB   le corridor franchit la rue (les conducteurs passent au-dessus)
-- LONGEMENT  la rue suit le corridor sur une distance notable
--
-- La table source du Livrable A est résolue dynamiquement.
-- ============================================================================

DO $voirie$
DECLARE
    tbl     text;
    sch     text;
    col_id  text;
    col_geo text;
    n       integer;
BEGIN
    SELECT table_schema, table_name INTO sch, tbl
    FROM information_schema.tables
    WHERE table_schema IN ('raw', 'uti')
      AND table_name IN ('troncons_entiers', 'troncon', 'troncons',
                         'troncons_polygones', 'reseau_routier')
    ORDER BY array_position(
        ARRAY['troncons_entiers','troncon','troncons',
              'troncons_polygones','reseau_routier'], table_name)
    LIMIT 1;

    IF tbl IS NULL THEN
        INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
        SELECT 'CONFLITS_VOIRIE', 'INFO',
               'Aucune table de tronçons routiers trouvée — les croisements entre '
               'corridors électriques et voirie ne sont pas calculés.',
               'Charger la couche des tronçons du Livrable A puis relancer 22.'
        WHERE NOT EXISTS (
            SELECT 1 FROM uti.t2h_elec_journal_blocages
            WHERE etape = 'CONFLITS_VOIRIE' AND severite = 'INFO');
        RAISE NOTICE '[INFO] table de tronçons introuvable.';
        RETURN;
    END IF;

    SELECT column_name INTO col_id
    FROM information_schema.columns
    WHERE table_schema = sch AND table_name = tbl
      AND lower(column_name) IN ('id_trc', 'id_troncon', 'id_troncon_entier')
    ORDER BY array_position(
        ARRAY['id_trc','id_troncon','id_troncon_entier'], lower(column_name))
    LIMIT 1;

    SELECT column_name INTO col_geo
    FROM information_schema.columns
    WHERE table_schema = sch AND table_name = tbl
      AND lower(column_name) IN ('geom', 'geometry', 'the_geom')
    LIMIT 1;

    IF col_geo IS NULL THEN
        RAISE NOTICE '[AVERT] colonne géométrique introuvable dans %.%', sch, tbl;
        RETURN;
    END IF;

    col_id := coalesce(col_id, 'ctid');

    EXECUTE format($fmt$
        INSERT INTO uti.t2h_elec_conflits_voirie (
            id_corridor, id_trc, type_conflit, geom
        )
        SELECT
            c.id_corridor,
            t.%3$I::text,
            'SURPLOMB',
            ST_Multi(ST_CollectionExtract(ST_Intersection(c.geom, t.%4$I), 1))
        FROM uti.t2h_elec_corridors c
        JOIN %1$I.%2$I t ON ST_Intersects(c.geom, t.%4$I)
    $fmt$, sch, tbl, col_id, col_geo);

    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '[OK] Conflits de voirie : % (source %.%)', n, sch, tbl;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[AVERT] Conflits de voirie non calculés : %', SQLERRM;
END
$voirie$;


-- ============================================================================
-- RATTACHEMENT DES CONFLITS AUX SECTIONS
-- ============================================================================

UPDATE uti.t2h_elec_conflits_voirie v
SET id_section = s.id_section
FROM uti.t2h_elec_sections s
WHERE s.id_corridor = v.id_corridor
  AND v.id_section IS NULL
  AND v.geom IS NOT NULL
  AND ST_Intersects(s.geom, v.geom);


-- ============================================================================
-- BILAN
-- ============================================================================

DO $bilan$
DECLARE
    n_inc integer;
    n_int integer;
    n_vo  integer;
BEGIN
    SELECT count(*) INTO n_inc FROM uti.t2h_elec_incursions;
    SELECT count(*) INTO n_int FROM uti.t2h_elec_interferences;
    SELECT count(*) INTO n_vo  FROM uti.t2h_elec_conflits_voirie;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE '  incursions      : %', n_inc;
    RAISE NOTICE '  interférences   : %', n_int;
    RAISE NOTICE '  conflits voirie : %', n_vo;
    RAISE NOTICE '--------------------------------------------------';
END
$bilan$;


-- ============================================================================
-- VUE DE SYNTHÈSE — ce qui occupe l'espace des emprises
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_t2h_elec_occupation AS
SELECT
    'INCURSION'              AS categorie,
    i.type_incursion         AS type_objet,
    count(*)                 AS n,
    ROUND(sum(i.surface_m2)) AS surface_m2
FROM uti.t2h_elec_incursions i
GROUP BY i.type_incursion
UNION ALL
SELECT
    'INTERFERENCE',
    f.famille || ' / ' || f.type_actif,
    count(*),
    NULL
FROM uti.t2h_elec_interferences f
GROUP BY f.famille, f.type_actif
UNION ALL
SELECT
    'CONFLIT_VOIRIE',
    coalesce(v.type_conflit, 'NON_QUALIFIE'),
    count(*),
    NULL
FROM uti.t2h_elec_conflits_voirie v
GROUP BY v.type_conflit
ORDER BY 1, 3 DESC;

COMMENT ON VIEW uti.v_t2h_elec_occupation IS
  'Ce qui occupe ou interfère avec l''espace des emprises — répond à l''exigence '
  'du mandat sur le répertoire des infrastructures urbaines et naturelles.';