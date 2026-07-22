-- ============================================================================
-- 16_referentiels.sql   —   RÉFÉRENTIELS RÉGLEMENTAIRES
-- ----------------------------------------------------------------------------
-- Alimente les deux tables de correspondance qui gouvernent tout le volet :
--   uti.t2h_elec_regles_degagement  tension -> largeur d'emprise
--   uti.t2h_elec_foncier_regime     code d'utilisation -> régime PUBLIC/PRIVE
--
-- AUCUNE distance ni classification n'existe en dur ailleurs dans le pipeline.
-- Pour changer une valeur, modifier ce fichier et relancer 18 à 21.
--
-- CONTRAINTE DU RUNNER : aucun point-virgule dans un littéral SQL.
-- Exécution : python scripts/02_run_sql_pipeline.py --only 16
-- ============================================================================

TRUNCATE TABLE uti.t2h_elec_regles_degagement RESTART IDENTITY CASCADE;
TRUNCATE TABLE uti.t2h_elec_foncier_regime    RESTART IDENTITY CASCADE;


-- ============================================================================
-- 1 — LARGEURS D'EMPRISE PAR PALIER DE TENSION
-- ----------------------------------------------------------------------------
-- SEULE VALEUR ANCRÉE : une ligne à 735 kV requiert une emprise de 80,0 à
--   91,5 m de largeur totale. C'est la seule largeur d'emprise publiée par
--   Hydro-Québec. On retient la borne haute, soit 45,75 m de demi-largeur.
--
-- TOUS LES AUTRES PALIERS sont DÉRIVÉS par proportionnalité au gabarit des
--   supports. Hydro-Québec ne publie pas de barème. Ces valeurs doivent être
--   remplacées dès qu'il sera obtenu.
--
-- VALEURS PUBLIÉES conservées pour tous les paliers :
--   végétation permise en emprise : 2,5 m de hauteur à maturité
--   passage d'accès à préserver   : 4 m de largeur
-- ============================================================================

INSERT INTO uti.t2h_elec_regles_degagement
    (reseau, tension_kv_min, tension_kv_max, config_reseau,
     demi_largeur_m, hauteur_veg_max_m, passage_acces_m,
     statut, source_reference, commentaire)
VALUES
    ('TRANSPORT', 600.00, 800.00, NULL,
     45.75, 2.50, 4.00, 'HYPOTHESE',
     'Emprise de 80,0 à 91,5 m documentée pour une ligne à 735 kV',
     'Borne haute retenue par prudence. Seule largeur du barème reposant sur une '
     'source publiée. Statut HYPOTHESE car la largeur réelle dépend de la '
     'servitude notariée propre à chaque lot.'),

    ('TRANSPORT', 250.00, 450.00, NULL,
     30.00, 2.50, 4.00, 'HYPOTHESE',
     'VALEUR DÉRIVÉE — aucune largeur publiée pour ce palier',
     'Palier 315 kV. Demi-largeur de 30 m, soit une emprise de 60 m. À REMPLACER '
     'par le barème Hydro-Québec.'),

    ('TRANSPORT', 180.00, 249.99, NULL,
     25.00, 2.50, 4.00, 'HYPOTHESE',
     'VALEUR DÉRIVÉE — aucune largeur publiée pour ce palier',
     'Palier 230 kV. Demi-largeur de 25 m. À REMPLACER par le barème Hydro-Québec.'),

    ('TRANSPORT', 100.00, 179.99, NULL,
     20.00, 2.50, 4.00, 'HYPOTHESE',
     'VALEUR DÉRIVÉE — aucune largeur publiée pour ce palier',
     'Palier 120 kV. Demi-largeur de 20 m. À REMPLACER par le barème Hydro-Québec.'),

    ('TRANSPORT', 40.00, 99.99, NULL,
     15.00, 2.50, 4.00, 'HYPOTHESE',
     'VALEUR DÉRIVÉE — aucune largeur publiée pour ce palier',
     'Paliers 44 à 69 kV, bas du réseau de transport. Demi-largeur de 15 m. '
     'À REMPLACER par le barème Hydro-Québec.'),

    ('TRANSPORT', NULL, NULL, NULL,
     20.00, 2.50, 4.00, 'HYPOTHESE',
     'VALEUR DE REPLI — tension non attribuée',
     'Appliqué aux corridors dont la tension n''a pu être recoupée. Aucun '
     'fondement — signalé comme tel dans la couche livrable.'),

    -- ---- DISTRIBUTION : valeurs publiées, mais aucune donnée au corpus ----
    ('DISTRIBUTION', 0.75, 34.50, 'MONOPHASE',
     5.00, NULL, NULL, 'VALIDE',
     'Hydro-Québec — Clauses techniques particulières : élagage, déboisement, débroussaillage et abattage (2024-09-20)',
     'Déboisement 5 m de part et d''autre du centre-ligne. Règle ORPHELINE : le '
     'corpus ne contient aucune donnée de réseau de distribution.'),

    ('DISTRIBUTION', 0.75, 34.50, 'TRIPHASE',
     6.50, NULL, NULL, 'VALIDE',
     'Hydro-Québec — Clauses techniques particulières (2024-09-20)',
     'Déboisement 6,5 m de part et d''autre du centre-ligne. Règle ORPHELINE.');


-- ============================================================================
-- 2 — RÉGIME FONCIER PAR CODE D'UTILISATION
-- ----------------------------------------------------------------------------
-- Le rôle d'évaluation public de Montréal ne diffuse PAS l'identité des
-- propriétaires. Le régime est donc déduit du CODE_UTILI selon la logique du
-- manuel d'évaluation foncière : 1xxx résidentiel, 2xxx-3xxx industriel,
-- 4xxx transport, 5xxx-6xxx commercial et services, 7xxx loisir, 8xxx
-- production de biens, 9xxx terrain vague.
--
-- Couverture mesurée : 100 % des lots à moins de 30 m d'un corridor.
-- ============================================================================

INSERT INTO uti.t2h_elec_foncier_regime
    (code_prefixe, match_exact, regime, famille, statut, commentaire)
VALUES
    -- ---- PUBLIC : domaine routier, codes exacts prioritaires ----
    ('4550', true, 'PUBLIC', 'Voie publique', 'CERTAIN',
     'Rue et avenue pour l''accès local.'),
    ('4561', true, 'PUBLIC', 'Voie publique', 'CERTAIN', 'Ruelle.'),
    ('4562', true, 'PUBLIC', 'Voie publique', 'CERTAIN', 'Passage.'),
    ('4590', true, 'PUBLIC', 'Voie publique', 'CERTAIN',
     'Autres routes et voies publiques.'),
    ('4111', true, 'PUBLIC', 'Réseau ferroviaire', 'HEURISTIQUE',
     'Chemin de fer — utilité publique, mais peut appartenir à un opérateur privé.'),

    -- ---- PUBLIC : loisir et institutionnel ----
    ('7',  false, 'PUBLIC', 'Loisir et parc', 'HEURISTIQUE',
     'Série 7xxx. Majoritairement municipal, quelques exceptions privées.'),
    ('68', false, 'PUBLIC', 'Enseignement', 'HEURISTIQUE',
     'Série 68xx. Le code ne distingue pas public et privé.'),
    ('69', false, 'INDETERMINE', 'Culte et institutionnel', 'HEURISTIQUE',
     'Série 69xx. Statut variable.'),

    -- ---- PRIVE ----
    ('1', false, 'PRIVE', 'Résidentiel', 'HEURISTIQUE',
     'Série 1xxx — logement, stationnements de condo, rangement.'),
    ('2', false, 'PRIVE', 'Industriel léger', 'HEURISTIQUE', 'Série 2xxx.'),
    ('3', false, 'PRIVE', 'Industriel', 'HEURISTIQUE', 'Série 3xxx.'),
    ('4', false, 'PRIVE', 'Transport privé', 'HEURISTIQUE',
     'Série 4xxx résiduelle — stationnements privés. Les voies publiques sont '
     'traitées par règles exactes ci-dessus.'),
    ('5', false, 'PRIVE', 'Commercial', 'HEURISTIQUE',
     'Série 5xxx — commerces, hôtels, entreposage.'),
    ('6', false, 'PRIVE', 'Services', 'HEURISTIQUE',
     'Série 6xxx — bureaux et services, sauf 68xx et 69xx.'),
    ('8', false, 'PRIVE', 'Production de biens', 'HEURISTIQUE',
     'Série 8xxx — extraction, transformation.'),
    ('9', false, 'PRIVE', 'Terrain vague', 'HEURISTIQUE',
     'Série 9xxx. PRIVE par défaut, certains sont des réserves municipales.');


-- ============================================================================
-- 3 — CONSIGNATION DES RÉSERVES
-- ============================================================================

DELETE FROM uti.t2h_elec_journal_blocages WHERE etape IN ('LARGEURS', 'FONCIER', 'DISTRIBUTION');

INSERT INTO uti.t2h_elec_journal_blocages (etape, severite, motif, action_requise)
VALUES
    ('LARGEURS', 'AVERTISSEMENT',
     'Seule la largeur d''emprise du palier 735 kV repose sur une source publiée. '
     'Les largeurs des paliers 315, 230, 120 et 69 kV sont DÉRIVÉES par '
     'proportionnalité, sans fondement réglementaire. Toutes les surfaces '
     'd''emprise du livrable sont donc INDICATIVES.',
     'Demander à Hydro-Québec le barème des largeurs d''emprise par palier. Ce '
     'n''est pas une demande de données réseau mais de documentation technique — '
     'démarche légère à fort rendement. Puis mettre à jour 16 et relancer 18 à 21.'),

    ('FONCIER', 'AVERTISSEMENT',
     'Le régime PUBLIC ou PRIVE est déduit du code d''utilisation, le rôle '
     'd''évaluation public ne diffusant pas l''identité des propriétaires. Une '
     'école ou un parc peut être privé. Classification fiable à environ 90 pour cent.',
     'Vérifier manuellement le régime des sections sensibles, celles où l''accès '
     'propriétaire est en jeu.'),

    ('DISTRIBUTION', 'AVERTISSEMENT',
     'Les règles DISTRIBUTION, déboisement de 5 m et 6,5 m, sont au statut VALIDE '
     'mais ORPHELINES : le corpus ne contient aucune donnée de réseau de '
     'distribution. La couche poles_mtl est la géobase des côtés de rue.',
     'Soit acquérir une donnée de distribution, soit retirer ce volet du '
     'périmètre et en informer le client.');

-- ============================================================================
-- FIN 16_referentiels.sql
-- ============================================================================
