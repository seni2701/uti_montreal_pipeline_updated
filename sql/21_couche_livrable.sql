-- ============================================================================
-- 21_couche_livrable.sql   —   COUCHE MAÎTRESSE LIVRABLE UNIQUE
-- ----------------------------------------------------------------------------
-- Pendant T2H de la couche maîtresse du Livrable A routier.
--
-- PRINCIPE : UNE SEULE COUCHE contient TOUS les niveaux de la chaîne, et CHAQUE
--   entité porte l'INTÉGRALITÉ du contexte hérité de ses parents. Un clic donne
--   la fiche complète — du corridor jusqu'à l'emplacement — sans consulter une
--   autre couche.
--
--   CORRIDOR          linéaire     unité de découpage
--   LIGNE             linéaire     circuits
--   PYLONE            surfacique   empreinte au sol
--   POSTE             surfacique   transformation
--   EMPRISE_AERIENNE  surfacique   bande réglementaire
--   EMPRISE_SOL       surfacique   occupation physique
--   SECTION           surfacique   tronçon du volet T2H
--   EMPLACEMENT       surfacique   plus petite représentation
--
-- GÉOMÉTRIE HÉTÉROGÈNE ASSUMÉE : contrairement à la couche routière, entièrement
--   surfacique, les corridors et lignes électriques sont LINÉAIRES par nature.
--   Conséquence QGIS : symbologie PAR RÈGLES sur `niveau`.
--
-- DÉNORMALISATION VOULUE : les attributs du corridor sont répétés sur chacun de
--   ses membres. C'est une couche de LIVRAISON, pas un modèle normalisé.
--   NE JAMAIS l'éditer — elle est régénérée à chaque exécution.
--
-- PRÉREQUIS : 17_ à 20_ (et 22_ pour l'occupation)
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 21_
-- ============================================================================

TRUNCATE TABLE uti.couche_livrable_t2h RESTART IDENTITY;


-- ============================================================================
-- NOTE DE LIMITE — construite selon l'état réel de la chaîne
-- ============================================================================

CREATE OR REPLACE FUNCTION uti.f_note_limite_t2h()
RETURNS text
LANGUAGE sql STABLE AS $fn$
    SELECT nullif(concat_ws(' ',
        CASE WHEN NOT EXISTS (SELECT 1 FROM uti.t2h_elec_emprises)
             THEN 'Socle géométrique seul — aucune emprise produite.' END,
        CASE WHEN EXISTS (SELECT 1 FROM uti.t2h_elec_regles_degagement
                          WHERE reseau = 'TRANSPORT' AND statut = 'HYPOTHESE')
             THEN 'Largeurs d''emprise NON VALIDÉES par Hydro-Québec — toutes les '
                  'surfaces sont INDICATIVES.' END,
        CASE WHEN EXISTS (SELECT 1 FROM uti.t2h_elec_lignes
                          WHERE tension_origine ILIKE '%OSM%')
             THEN 'Tension attribuée par recoupement OpenStreetMap (ODbL), non '
                  'confirmée par Hydro-Québec.' END,
        'Voir la table t2h_elec_journal_blocages incluse dans ce fichier.'
    ), '')
$fn$;


-- ============================================================================
-- NIVEAU 1 — CORRIDORS
-- ============================================================================

INSERT INTO uti.couche_livrable_t2h (
    id_treevans, niveau, type_geom, arrondissement, id_utg,
    corridor_id, corridor_ref, corridor_longueur_m,
    corridor_nb_lignes, corridor_nb_pylones,
    reseau, exploitant, tension_kv, tension_origine,
    longueur_m, chaine_complete, note_limite, recherche, geom
)
SELECT
    c.id_treevans, 'CORRIDOR', 'LINEAIRE', c.arrondissement, c.id_utg,
    c.id_corridor, c.id_treevans, c.longueur_axe_m,
    c.nb_lignes, c.nb_pylones,
    c.reseau, c.exploitant, c.tension_kv, c.tension_origine,
    c.longueur_axe_m,
    EXISTS (SELECT 1 FROM uti.t2h_elec_emplacements),
    uti.f_note_limite_t2h(),
    concat_ws(' ', c.id_treevans, 'corridor', c.arrondissement),
    c.geom
FROM uti.t2h_elec_corridors c;


-- ============================================================================
-- NIVEAU 2 — LIGNES
-- ============================================================================

INSERT INTO uti.couche_livrable_t2h (
    id_treevans, niveau, type_geom, arrondissement, id_utg,
    corridor_id, corridor_ref, corridor_longueur_m,
    corridor_nb_lignes, corridor_nb_pylones,
    reseau, exploitant, tension_kv, tension_origine,
    longueur_m, chaine_complete, note_limite, recherche, geom
)
SELECT
    l.id_treevans, 'LIGNE', 'LINEAIRE', l.arrondissement, l.id_utg,
    c.id_corridor, c.id_treevans, c.longueur_axe_m,
    c.nb_lignes, c.nb_pylones,
    l.reseau, l.exploitant, l.tension_kv, l.tension_origine,
    l.longueur_m,
    EXISTS (SELECT 1 FROM uti.t2h_elec_emplacements),
    uti.f_note_limite_t2h(),
    concat_ws(' ', l.id_treevans, 'ligne', l.nom_ligne, l.arrondissement),
    l.geom
FROM uti.t2h_elec_lignes l
LEFT JOIN uti.t2h_elec_corridors c ON c.id_corridor = l.id_corridor;


-- ============================================================================
-- NIVEAU 3 — PYLÔNES
-- ============================================================================

INSERT INTO uti.couche_livrable_t2h (
    id_treevans, niveau, type_geom, arrondissement, id_utg,
    corridor_id, corridor_ref, corridor_longueur_m,
    corridor_nb_lignes, corridor_nb_pylones,
    reseau, exploitant, tension_kv,
    surface_m2, candidat_poste, empreinte_fiable,
    chaine_complete, note_limite, recherche, geom
)
SELECT
    p.id_treevans, 'PYLONE', 'SURFACIQUE', p.arrondissement, p.id_utg,
    c.id_corridor, c.id_treevans, c.longueur_axe_m,
    c.nb_lignes, c.nb_pylones,
    'TRANSPORT', 'Hydro-Québec', c.tension_kv,
    p.surface_m2, p.candidat_poste, p.empreinte_fiable,
    EXISTS (SELECT 1 FROM uti.t2h_elec_emplacements),
    uti.f_note_limite_t2h(),
    concat_ws(' ', p.id_treevans, 'pylône', p.type_support, p.arrondissement,
              CASE WHEN p.candidat_poste THEN 'candidat poste' END),
    p.geom_polygone
FROM uti.t2h_elec_pylones p
LEFT JOIN uti.t2h_elec_corridors c ON c.id_corridor = p.id_corridor
WHERE p.geom_polygone IS NOT NULL;


-- ============================================================================
-- NIVEAU 4 — POSTES
-- ============================================================================

INSERT INTO uti.couche_livrable_t2h (
    id_treevans, niveau, type_geom, arrondissement, id_utg,
    reseau, exploitant, tension_kv, surface_m2,
    chaine_complete, note_limite, recherche, geom
)
SELECT
    po.id_treevans, 'POSTE', 'SURFACIQUE', po.arrondissement, po.id_utg,
    'TRANSPORT', po.exploitant, po.tension_kv, po.surface_m2,
    po.confirme,
    CASE WHEN NOT po.confirme
         THEN 'Poste DÉDUIT par topologie (empreinte large et circuits qui s''y '
              'terminent), non confirmé par photo-interprétation.'
         ELSE NULL END,
    concat_ws(' ', po.id_treevans, 'poste', po.nom_poste, po.arrondissement),
    po.geom
FROM uti.t2h_elec_postes po;


-- ============================================================================
-- NIVEAUX 5 et 6 — EMPRISES AÉRIENNE ET SOL
-- ============================================================================

INSERT INTO uti.couche_livrable_t2h (
    id_treevans, niveau, type_geom, arrondissement, id_utg,
    corridor_id, corridor_ref, corridor_longueur_m,
    corridor_nb_lignes, corridor_nb_pylones,
    reseau, exploitant, tension_kv, tension_origine,
    emprise_ref, type_emprise, demi_largeur_m, origine_geom,
    statut_regle, licence_source, hauteur_veg_max_m, passage_acces_m,
    surface_m2, chaine_complete, note_limite, recherche, geom
)
SELECT
    e.id_treevans,
    'EMPRISE_' || e.type_emprise,
    'SURFACIQUE', e.arrondissement, e.id_utg,
    c.id_corridor, c.id_treevans, c.longueur_axe_m,
    c.nb_lignes, c.nb_pylones,
    c.reseau, c.exploitant, e.tension_kv, c.tension_origine,
    e.id_treevans, e.type_emprise, e.demi_largeur_m, e.origine_geom,
    e.statut_regle, e.licence_source, g.hauteur_veg_max_m, g.passage_acces_m,
    e.surface_m2,
    EXISTS (SELECT 1 FROM uti.t2h_elec_emplacements),
    uti.f_note_limite_t2h(),
    concat_ws(' ', e.id_treevans, 'emprise', e.type_emprise, e.arrondissement),
    e.geom
FROM uti.t2h_elec_emprises e
LEFT JOIN uti.t2h_elec_corridors c ON c.id_corridor = e.id_corridor
LEFT JOIN uti.t2h_elec_regles_degagement g ON g.id_regle = e.id_regle;


-- ============================================================================
-- NIVEAU 7 — SECTIONS
-- ============================================================================

INSERT INTO uti.couche_livrable_t2h (
    id_treevans, niveau, type_geom, arrondissement, id_utg,
    corridor_id, corridor_ref, corridor_longueur_m,
    corridor_nb_lignes, corridor_nb_pylones,
    reseau, exploitant, tension_kv, tension_origine,
    emprise_ref, type_emprise, demi_largeur_m, origine_geom,
    statut_regle, licence_source,
    section_ref, zonage_affectation, regime_foncier, motif_decoupe, nb_lots,
    longueur_m, surface_m2, chaine_complete, note_limite, recherche, geom
)
SELECT
    s.id_treevans, 'SECTION', 'SURFACIQUE', s.arrondissement, s.id_utg,
    c.id_corridor, c.id_treevans, c.longueur_axe_m,
    c.nb_lignes, c.nb_pylones,
    c.reseau, c.exploitant, s.tension_kv, c.tension_origine,
    e.id_treevans, e.type_emprise, e.demi_largeur_m, e.origine_geom,
    e.statut_regle, e.licence_source,
    s.id_treevans, s.zonage_affectation, s.regime_foncier, s.motif_decoupe, s.nb_lots,
    s.longueur_m, s.surface_m2,
    true,
    uti.f_note_limite_t2h(),
    concat_ws(' ', s.id_treevans, 'section', s.zonage_affectation,
                   s.regime_foncier, s.arrondissement),
    s.geom
FROM uti.t2h_elec_sections s
LEFT JOIN uti.t2h_elec_emprises  e ON e.id_emprise  = s.id_emprise
LEFT JOIN uti.t2h_elec_corridors c ON c.id_corridor = s.id_corridor;


-- ============================================================================
-- NIVEAU 8 — EMPLACEMENTS (plus fin niveau du mandat)
-- ============================================================================

INSERT INTO uti.couche_livrable_t2h (
    id_treevans, niveau, type_geom, arrondissement, id_utg,
    corridor_id, corridor_ref, corridor_longueur_m,
    corridor_nb_lignes, corridor_nb_pylones,
    reseau, exploitant, tension_kv, tension_origine,
    emprise_ref, type_emprise, demi_largeur_m, origine_geom,
    statut_regle, licence_source, hauteur_veg_max_m, passage_acces_m,
    section_ref, zonage_affectation, regime_foncier, motif_decoupe, nb_lots,
    orientation, activite, activite_autorisee, accessible_prop,
    adresse, code_postal,
    surface_m2, longueur_m, chaine_complete, note_limite, recherche, geom
)
SELECT
    em.id_treevans, 'EMPLACEMENT', 'SURFACIQUE', s.arrondissement, s.id_utg,
    c.id_corridor, c.id_treevans, c.longueur_axe_m,
    c.nb_lignes, c.nb_pylones,
    c.reseau, c.exploitant, s.tension_kv, c.tension_origine,
    e.id_treevans, e.type_emprise, e.demi_largeur_m, e.origine_geom,
    e.statut_regle, e.licence_source, g.hauteur_veg_max_m, g.passage_acces_m,
    s.id_treevans, s.zonage_affectation, s.regime_foncier, s.motif_decoupe, s.nb_lots,
    em.orientation, em.activite, em.activite_autorisee, em.accessible_prop,
    em.adresse, em.code_postal,
    em.surface_m2, em.perimetre_m,
    true,
    uti.f_note_limite_t2h(),
    COALESCE(em.recherche, em.id_treevans),
    em.geom
FROM uti.t2h_elec_emplacements em
LEFT JOIN uti.t2h_elec_sections  s ON s.id_section  = em.id_section
LEFT JOIN uti.t2h_elec_emprises  e ON e.id_emprise  = s.id_emprise
LEFT JOIN uti.t2h_elec_regles_degagement g ON g.id_regle = e.id_regle
LEFT JOIN uti.t2h_elec_corridors c ON c.id_corridor = s.id_corridor;


-- ============================================================================
-- CONTRÔLE
-- ============================================================================

CREATE OR REPLACE VIEW uti.v_couche_livrable_composition AS
SELECT
    niveau,
    type_geom,
    count(*)                               AS n,
    count(*) FILTER (WHERE candidat_poste) AS dont_candidats_postes,
    ROUND(sum(longueur_m))                 AS longueur_m,
    ROUND(sum(surface_m2))                 AS surface_m2,
    ROUND(sum(surface_m2)/10000.0, 2)      AS surface_ha,
    count(DISTINCT arrondissement)         AS nb_arrondissements
FROM uti.couche_livrable_t2h
GROUP BY niveau, type_geom
ORDER BY CASE niveau
    WHEN 'CORRIDOR'         THEN 1
    WHEN 'LIGNE'            THEN 2
    WHEN 'PYLONE'           THEN 3
    WHEN 'POSTE'            THEN 4
    WHEN 'EMPRISE_AERIENNE' THEN 5
    WHEN 'EMPRISE_SOL'      THEN 6
    WHEN 'SECTION'          THEN 7
    ELSE 8 END;

COMMENT ON VIEW uti.v_couche_livrable_composition IS
  'Composition de la couche maîtresse par niveau. Un niveau à 0 signale un '
  'maillon bloqué — voir uti.t2h_elec_journal_blocages.';


DO $bilan$
DECLARE
    n_tot integer;
    n_niv text;
BEGIN
    SELECT count(*) INTO n_tot FROM uti.couche_livrable_t2h;
    SELECT string_agg(DISTINCT niveau, ', ') INTO n_niv FROM uti.couche_livrable_t2h;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE '  couche_livrable_t2h : % entités', n_tot;
    RAISE NOTICE '  niveaux présents    : %', n_niv;
    RAISE NOTICE '--------------------------------------------------';
END
$bilan$;