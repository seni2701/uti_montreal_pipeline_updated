-- ============================================================================
-- 21b_vues_controle.sql   —   VUES DE CONTRÔLE TRANSVERSALES
-- ----------------------------------------------------------------------------
-- Complète la série 15 à 21 avec les vues de pilotage utilisées par
-- l'orchestrateur (04_run_livrable_D.py) et l'export GeoPackage.
--
-- Placée en 21b car elle lit toutes les tables de la chaîne : elle doit
-- s'exécuter en dernier.
--
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 21b
-- ============================================================================

-- ============================================================================
-- AVANCEMENT — état de chaque maillon de la chaîne
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_t2h_elec_avancement AS
SELECT 'CORRIDORS' AS etape, 1 AS ordre, count(*) AS n,
       CASE WHEN count(*) > 0 THEN 'OK' ELSE 'BLOQUE' END AS statut
FROM uti.t2h_elec_corridors
UNION ALL
SELECT 'LIGNES', 2, count(*),
       CASE WHEN count(*) > 0 THEN 'OK' ELSE 'BLOQUE' END
FROM uti.t2h_elec_lignes
UNION ALL
SELECT 'PYLONES', 3, count(*),
       CASE WHEN count(*) > 0 THEN 'OK' ELSE 'BLOQUE' END
FROM uti.t2h_elec_pylones
UNION ALL
SELECT 'POSTES', 4, count(*),
       CASE WHEN count(*) > 0 THEN 'OK' ELSE 'BLOQUE' END
FROM uti.t2h_elec_postes
UNION ALL
SELECT 'EMPRISES', 5, count(*),
       CASE WHEN count(*) > 0 THEN 'OK' ELSE 'BLOQUE' END
FROM uti.t2h_elec_emprises
UNION ALL
SELECT 'SECTIONS', 6, count(*),
       CASE WHEN count(*) > 0 THEN 'OK' ELSE 'BLOQUE' END
FROM uti.t2h_elec_sections
UNION ALL
SELECT 'EMPLACEMENTS', 7, count(*),
       CASE WHEN count(*) > 0 THEN 'OK' ELSE 'BLOQUE' END
FROM uti.t2h_elec_emplacements
UNION ALL
SELECT 'REL_LOTS', 8, count(*),
       CASE WHEN count(*) > 0 THEN 'OK' ELSE 'BLOQUE' END
FROM uti.t2h_elec_rel_lots;

COMMENT ON VIEW uti.v_t2h_elec_avancement IS
  'Avancement de la chaîne T2H électrique. Un maillon BLOQUE trouve son motif '
  'dans uti.t2h_elec_journal_blocages.';


-- ============================================================================
-- ALIAS DE COMPATIBILITÉ
-- ----------------------------------------------------------------------------
-- La série réécrite nomme certaines vues sans le segment « elec ». Ces alias
-- évitent d'avoir à modifier les scripts Python, et documentent l'équivalence.
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_t2h_elec_bilan_corridor AS
SELECT * FROM uti.v_t2h_bilan_corridor;

COMMENT ON VIEW uti.v_t2h_elec_bilan_corridor IS
  'Alias de uti.v_t2h_bilan_corridor. Synthèse par corridor, profil Gestionnaire.';


CREATE OR REPLACE VIEW uti.v_t2h_elec_tension_bilan AS
SELECT * FROM uti.v_t2h_tension_bilan;

COMMENT ON VIEW uti.v_t2h_elec_tension_bilan IS
  'Alias de uti.v_t2h_tension_bilan. Répartition des tensions attribuées.';


-- ============================================================================
-- CANDIDATS POSTES — empreintes à photo-interpréter
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_t2h_elec_candidats_postes AS
SELECT
    p.id_pylone,
    p.id_treevans,
    p.id_corridor,
    p.arrondissement,
    p.surface_m2,
    ROUND(ST_Perimeter(p.geom_polygone)::numeric, 2) AS perimetre_m,
    p.empreinte_fiable,
    (SELECT count(DISTINCT l.id_ligne)
     FROM uti.t2h_elec_lignes l, LATERAL ST_Dump(l.geom) d
     WHERE ST_DWithin(ST_StartPoint(d.geom), p.geom_polygone, 30)
        OR ST_DWithin(ST_EndPoint(d.geom),   p.geom_polygone, 30)
    ) AS lignes_terminant,
    p.geom_polygone AS geom
FROM uti.t2h_elec_pylones p
WHERE p.candidat_poste
ORDER BY p.surface_m2 DESC;

COMMENT ON VIEW uti.v_t2h_elec_candidats_postes IS
  'Empreintes larges candidates au statut de poste. lignes_terminant est le '
  'critère décisif — un pylône est traversé, un poste est un terminus.';


-- ============================================================================
-- SYNTHÈSE DU LIVRABLE — une ligne, pour le rapport client
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_t2h_elec_synthese_livrable AS
SELECT
    (SELECT count(*) FROM uti.t2h_elec_corridors)          AS nb_corridors,
    (SELECT count(*) FROM uti.t2h_elec_lignes)             AS nb_lignes,
    (SELECT count(*) FROM uti.t2h_elec_pylones)            AS nb_pylones,
    (SELECT ROUND(sum(longueur_axe_m)/1000.0, 1)
     FROM uti.t2h_elec_corridors)                          AS reseau_km,
    (SELECT count(*) FROM uti.t2h_elec_emprises
     WHERE type_emprise = 'AERIENNE')                      AS nb_emprises_aer,
    (SELECT ROUND(sum(surface_m2)/10000.0, 1)
     FROM uti.t2h_elec_emprises WHERE type_emprise = 'AERIENNE') AS emprise_aer_ha,
    (SELECT count(*) FROM uti.t2h_elec_sections)           AS nb_sections,
    (SELECT count(*) FROM uti.t2h_elec_emplacements)       AS nb_emplacements,
    (SELECT count(DISTINCT id_lot) FROM uti.t2h_elec_rel_lots
     WHERE type_relation IN ('INCLUS', 'GREVE'))           AS nb_lots_greves,
    (SELECT count(*) FROM uti.t2h_elec_journal_blocages
     WHERE severite = 'BLOQUANT')                          AS nb_bloquants,
    (SELECT bool_or(statut = 'HYPOTHESE')
     FROM uti.t2h_elec_regles_degagement
     WHERE reseau = 'TRANSPORT')                           AS surfaces_indicatives;

COMMENT ON VIEW uti.v_t2h_elec_synthese_livrable IS
  'Chiffres clés du Livrable D en une ligne. surfaces_indicatives à true '
  'signifie que les largeurs d''emprise ne sont pas validées par Hydro-Québec.';