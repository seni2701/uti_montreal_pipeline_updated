-- ============================================================================
-- 15_uti_hydroelectriques.sql   —   DDL COMPLET (réécriture 2026-07-14)
-- ----------------------------------------------------------------------------
-- UTI de transport HYDROÉLECTRIQUE (famille T2H, volet électrique)
-- Ville de Montréal / Treevans 2026
--
-- Cette version intègre dès le DDL tout ce qui avait été découvert en cours de
-- route et corrigé par suffixes. Les correctifs 15b, 15c, 16b, 16c, 16d, 17b,
-- 17d, 17e et 18b sont ABSORBÉS ici et n'existent plus comme fichiers séparés.
--
-- CORRECTIONS INTÉGRÉES :
--   - CORRIDOR est une table de plein droit (les 160 lignes sources forment
--     seulement 23 composantes connexes — la ligne n'est pas l'unité de découpage)
--   - PYLÔNE est polygonal (empreinte au sol réelle), le point est dérivé
--   - EMPRISE porte type_emprise (AERIENNE vs SOL) et id_corridor
--   - tension_kv est alimentée par recoupement OSM, avec traçabilité de source
--   - régime foncier déduit du code d'utilisation (le rôle ne diffuse pas les
--     propriétaires)
--
-- CONTRAINTE DU RUNNER : split_statements() découpe sur ";" sans suivre les
--   littéraux. RÈGLE ABSOLUE — aucun point-virgule dans une chaîne SQL.
--
-- CRS : EPSG:2950 (NAD83 MTM8)   Schémas : raw (sources), uti (résultats)
-- Exécution : python scripts/02_run_sql_pipeline.py --only 15
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS uti;

-- Ordre de suppression inverse des dépendances
DROP TABLE IF EXISTS uti.couche_livrable_t2h        CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_rel_lots          CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_incursions        CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_interferences     CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_conflits_voirie   CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_emplacements      CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_sections          CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_zones_securite    CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_emprises          CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_pylones           CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_lignes            CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_corridors         CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_postes            CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_regles_degagement CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_foncier_regime    CASCADE;
DROP TABLE IF EXISTS uti.t2h_elec_journal_blocages  CASCADE;


-- ============================================================================
-- SECTION 0 — JOURNAL DES BLOCAGES
-- ----------------------------------------------------------------------------
-- Créé en premier : tous les scripts avals y consignent leurs impossibilités.
-- L'absence de donnée devient une donnée, interrogeable et exportable.
-- ============================================================================

CREATE TABLE uti.t2h_elec_journal_blocages (
    id_blocage      serial PRIMARY KEY,
    etape           text NOT NULL,
    severite        text NOT NULL
                    CHECK (severite IN ('BLOQUANT', 'AVERTISSEMENT', 'INFO')),
    motif           text NOT NULL,
    action_requise  text,
    date_constat    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_journal_blocages IS
  'Registre des impossibilités de production et des réserves, avec l''action '
  'requise pour les lever. Voyage dans le GeoPackage livré. Doit être exempt de '
  'BLOQUANT avant présentation client.';


-- ============================================================================
-- SECTION 1 — RÉFÉRENTIELS RÉGLEMENTAIRES (paramétriques, non spatiaux)
-- ============================================================================

-- 1.1 Largeurs d'emprise par palier de tension
CREATE TABLE uti.t2h_elec_regles_degagement (
    id_regle            serial PRIMARY KEY,
    reseau              text NOT NULL
                        CHECK (reseau IN ('TRANSPORT', 'DISTRIBUTION')),
    tension_kv_min      numeric(8,2),
    tension_kv_max      numeric(8,2),
    config_reseau       text,
    demi_largeur_m      numeric(6,2),
    hauteur_veg_max_m   numeric(5,2),
    passage_acces_m     numeric(5,2),
    statut              text NOT NULL DEFAULT 'HYPOTHESE'
                        CHECK (statut IN ('VALIDE', 'HYPOTHESE', 'A_VALIDER')),
    source_reference    text,
    commentaire         text,
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_regles_degagement IS
  'Correspondance palier de tension vers largeur de bande réglementaire. SOURCE '
  'UNIQUE de toute largeur du volet T2H. Aucune distance en dur ailleurs — pour '
  'changer une valeur, modifier cette table et relancer 18 à 21.';

COMMENT ON COLUMN uti.t2h_elec_regles_degagement.statut IS
  'VALIDE = distance publiée et opposable. HYPOTHESE = valeur de travail '
  'documentée, à remplacer par le barème Hydro-Québec. A_VALIDER = inconnue.';

COMMENT ON COLUMN uti.t2h_elec_regles_degagement.demi_largeur_m IS
  'Distance de part et d''autre du centre-ligne.';


-- 1.2 Régime foncier déduit du code d'utilisation
CREATE TABLE uti.t2h_elec_foncier_regime (
    id_regle         serial PRIMARY KEY,
    code_prefixe     text NOT NULL,
    match_exact      boolean NOT NULL DEFAULT false,
    regime           text NOT NULL
                     CHECK (regime IN ('PUBLIC', 'PRIVE', 'INDETERMINE')),
    famille          text,
    statut           text NOT NULL DEFAULT 'HEURISTIQUE'
                     CHECK (statut IN ('CERTAIN', 'HEURISTIQUE')),
    commentaire      text
);

COMMENT ON TABLE uti.t2h_elec_foncier_regime IS
  'Correspondance CODE_UTILI du rôle d''évaluation vers régime PUBLIC ou PRIVE. '
  'Déduction nécessaire car le rôle public ne diffuse pas l''identité des '
  'propriétaires. Le régime HQ n''en vient PAS — une emprise grève un lot privé '
  'sans le rendre public, c''est la relation lot vers emprise qui porte la servitude.';


-- ============================================================================
-- SECTION 2 — INFRASTRUCTURE DE RÉFÉRENCE (étape 1 du mandat)
-- ============================================================================

-- 2.1 CORRIDOR — unité de découpage réelle
CREATE TABLE uti.t2h_elec_corridors (
    id_corridor            bigserial PRIMARY KEY,
    id_treevans            text UNIQUE,
    reseau                 text NOT NULL DEFAULT 'TRANSPORT'
                           CHECK (reseau IN ('TRANSPORT', 'DISTRIBUTION')),
    exploitant             text DEFAULT 'Hydro-Québec',
    nb_lignes              integer,
    nb_pylones             integer,
    nb_circuits_paralleles integer,
    longueur_axe_m         numeric(12,2),
    longueur_cumulee_m     numeric(12,2),
    tension_kv             numeric(8,2),
    tension_origine        text,
    arrondissement         text,
    id_utg                 text,
    geom                   geometry(MultiLineString, 2950) NOT NULL,
    geom_enveloppe         geometry(Polygon, 2950),
    date_maj               timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_corridors IS
  'Corridor = composante connexe du réseau, obtenue par regroupement spatial des '
  'lignes sources. UNITÉ DE DÉCOUPAGE du volet T2H — c''est le corridor, et non '
  'la ligne, qui est sectionné par le zonage. Analogue de uti.troncons_entiers.';

COMMENT ON COLUMN uti.t2h_elec_corridors.longueur_axe_m IS
  'Longueur de la géométrie fusionnée. C''est CETTE valeur qui décrit l''étendue '
  'réelle du réseau, jamais longueur_cumulee_m qui sur-compte les circuits parallèles.';

COMMENT ON COLUMN uti.t2h_elec_corridors.arrondissement IS
  'Convention pipeline — un corridor à cheval est encodé "X | Y".';

CREATE INDEX idx_t2h_corridors_geom ON uti.t2h_elec_corridors USING GIST (geom);


-- 2.2 LIGNE — circuit individuel
CREATE TABLE uti.t2h_elec_lignes (
    id_ligne            bigserial PRIMARY KEY,
    id_treevans         text UNIQUE,
    id_corridor         bigint REFERENCES uti.t2h_elec_corridors(id_corridor),
    id_source           text,
    source_donnee       text NOT NULL,
    reseau              text
                        CHECK (reseau IN ('TRANSPORT', 'DISTRIBUTION')),
    tension_kv          numeric(8,2),
    tension_origine     text,
    config_reseau       text,
    exploitant          text DEFAULT 'Hydro-Québec',
    nom_ligne           text,
    longueur_m          numeric(12,2),
    arrondissement      text,
    id_utg              text,
    geom                geometry(MultiLineString, 2950) NOT NULL,
    geom_source         geometry(MultiLineString, 2950),
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_lignes IS
  'Axe des circuits électriques. Source primaire — Ville de Montréal, couche '
  'CARTO-SER-ELE-TEL-AERIEN, millésime 2020, précision de 30 à 40 cm.';

COMMENT ON COLUMN uti.t2h_elec_lignes.tension_kv IS
  'La source Ville de Montréal ne porte AUCUN attribut de tension. Cette colonne '
  'est alimentée par recoupement OpenStreetMap — voir tension_origine.';

COMMENT ON COLUMN uti.t2h_elec_lignes.tension_origine IS
  'Provenance de la tension. OSM_ODBL indique une source contributive, non '
  'Hydro-Québec. Une validation HQ reste souhaitable.';

CREATE INDEX idx_t2h_lignes_geom     ON uti.t2h_elec_lignes USING GIST (geom);
CREATE INDEX idx_t2h_lignes_corridor ON uti.t2h_elec_lignes (id_corridor);


-- 2.3 PYLÔNE — empreinte au sol POLYGONALE
CREATE TABLE uti.t2h_elec_pylones (
    id_pylone           bigserial PRIMARY KEY,
    id_treevans         text UNIQUE,
    id_corridor         bigint REFERENCES uti.t2h_elec_corridors(id_corridor),
    id_ligne            bigint REFERENCES uti.t2h_elec_lignes(id_ligne),
    id_source           text,
    source_donnee       text NOT NULL,
    type_support        text,
    surface_m2          numeric(14,2),
    empreinte_fiable    boolean DEFAULT true,
    candidat_poste      boolean DEFAULT false,
    arrondissement      text,
    id_utg              text,
    geom_polygone       geometry(MultiPolygon, 2950) NOT NULL,
    geom                geometry(Point, 2950),
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_pylones IS
  'Supports des lignes. Source — CARTO-SER-ELECTRICITE (bases de béton, VMTL 2020). '
  'La source livre des POLYGONES : geom_polygone est la géométrie primaire, geom '
  'est un point dérivé pour la symbologie uniquement.';

COMMENT ON COLUMN uti.t2h_elec_pylones.id_ligne IS
  'Rattachement indicatif à la ligne la plus proche. ARTEFACT en présence de '
  'circuits parallèles — un pylône supporte plusieurs circuits. NE PAS utiliser '
  'pour un calcul. La clé faisant foi est id_corridor.';

COMMENT ON COLUMN uti.t2h_elec_pylones.empreinte_fiable IS
  'false pour les empreintes inférieures à 1 m2, qui sont des symboles de taille '
  'fixe et non des relevés photogrammétriques.';

COMMENT ON COLUMN uti.t2h_elec_pylones.candidat_poste IS
  'true pour les empreintes de plus de 300 m2. Candidat poste de transformation, '
  'à confirmer par photo-interprétation.';

CREATE INDEX idx_t2h_pylones_geom     ON uti.t2h_elec_pylones USING GIST (geom_polygone);
CREATE INDEX idx_t2h_pylones_corridor ON uti.t2h_elec_pylones (id_corridor);


-- 2.4 POSTE de transformation
CREATE TABLE uti.t2h_elec_postes (
    id_poste            bigserial PRIMARY KEY,
    id_treevans         text UNIQUE,
    id_pylone_source    bigint,
    id_source           text,
    source_donnee       text NOT NULL,
    nom_poste           text,
    tension_kv          numeric(8,2),
    exploitant          text DEFAULT 'Hydro-Québec',
    nb_lignes_terminant integer,
    surface_m2          numeric(14,2),
    confirme            boolean DEFAULT false,
    arrondissement      text,
    id_utg              text,
    geom                geometry(MultiPolygon, 2950) NOT NULL,
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_postes IS
  'Postes de transformation. Aucune source ouverte n''en fournit pour Montréal — '
  'ils sont déduits par topologie (empreinte vaste + circuits qui s''y terminent) '
  'depuis CARTO-SER-ELECTRICITE. La colonne confirme passe à true après '
  'photo-interprétation.';

CREATE INDEX idx_t2h_postes_geom ON uti.t2h_elec_postes USING GIST (geom);


-- ============================================================================
-- SECTION 3 — EMPRISES (étape 2 du mandat)
-- ============================================================================

CREATE TABLE uti.t2h_elec_emprises (
    id_emprise          bigserial PRIMARY KEY,
    id_treevans         text UNIQUE,
    id_corridor         bigint REFERENCES uti.t2h_elec_corridors(id_corridor),
    id_poste            bigint REFERENCES uti.t2h_elec_postes(id_poste),
    id_regle            integer REFERENCES uti.t2h_elec_regles_degagement(id_regle),

    type_emprise        text NOT NULL
                        CHECK (type_emprise IN ('AERIENNE', 'SOL')),
    origine_geom        text NOT NULL
                        CHECK (origine_geom IN (
                            'SERVITUDE_NOTARIEE',
                            'CADASTRE_HQ',
                            'HQ_VEGETATION',
                            'BUFFER_REGLEMENTAIRE',
                            'BUFFER_HYPOTHESE',
                            'EMPREINTE_PYLONE')),
    licence_source      text,
    tension_kv          numeric(8,2),
    demi_largeur_m      numeric(6,2),
    statut_regle        text,
    surface_m2          numeric(14,2),
    arrondissement      text,
    id_utg              text,
    geom                geometry(MultiPolygon, 2950) NOT NULL,
    date_maj            timestamptz NOT NULL DEFAULT now(),
    CHECK (id_corridor IS NOT NULL OR id_poste IS NOT NULL)
);

COMMENT ON TABLE uti.t2h_elec_emprises IS
  'Bandes adossées à l''infrastructure. DEUX géométries par corridor : AERIENNE '
  'est la bande réglementaire à dégager (buffer selon la tension), SOL est '
  'l''empreinte physique (bases de pylônes plus couloir d''accès). L''emprise '
  'réelle étant une servitude notariée lot par lot, elle n''est PAS reconstituable '
  'par buffer — origine_geom trace ce compromis.';

COMMENT ON COLUMN uti.t2h_elec_emprises.type_emprise IS
  'AERIENNE = espace à dégager, hachures rouges du mandat, largeur selon tension. '
  'SOL = empreinte physique, plus étroite, fondée sur le passage d''accès publié '
  'par Hydro-Québec. La SOL est la plus défendable des deux.';

CREATE INDEX idx_t2h_emprises_geom     ON uti.t2h_elec_emprises USING GIST (geom);
CREATE INDEX idx_t2h_emprises_corridor ON uti.t2h_elec_emprises (id_corridor);
CREATE INDEX idx_t2h_emprises_type     ON uti.t2h_elec_emprises (type_emprise);


CREATE TABLE uti.t2h_elec_zones_securite (
    id_zone             bigserial PRIMARY KEY,
    id_emprise          bigint REFERENCES uti.t2h_elec_emprises(id_emprise),
    type_zone           text NOT NULL
                        CHECK (type_zone IN ('DEGAGEMENT_VEGETATION',
                                             'AIRE_TRAVAIL',
                                             'PASSAGE_ACCES',
                                             'DISTANCE_APPROCHE')),
    hauteur_veg_max_m   numeric(5,2),
    largeur_m           numeric(6,2),
    symbologie          text NOT NULL DEFAULT 'HACHURE_ROUGE',
    statut_regle        text,
    surface_m2          numeric(14,2),
    geom                geometry(MultiPolygon, 2950) NOT NULL,
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_zones_securite IS
  'Espaces de sécurité à hachurer en ROUGE, convention visuelle explicite du '
  'mandat. Profil utilisateur — Gestionnaire.';

CREATE INDEX idx_t2h_zones_geom ON uti.t2h_elec_zones_securite USING GIST (geom);


-- ============================================================================
-- SECTION 4 — SECTIONS (étapes 3 et 4 du mandat)
-- ============================================================================

CREATE TABLE uti.t2h_elec_sections (
    id_section          bigserial PRIMARY KEY,
    id_treevans         text UNIQUE,
    id_emprise          bigint NOT NULL REFERENCES uti.t2h_elec_emprises(id_emprise),
    id_corridor         bigint REFERENCES uti.t2h_elec_corridors(id_corridor),
    ordre_section       integer,
    motif_decoupe       text NOT NULL
                        CHECK (motif_decoupe IN ('ZONAGE',
                                                 'REGIME_FONCIER',
                                                 'LIMITE_UTG',
                                                 'PONT',
                                                 'INFRA_TRANSPORT',
                                                 'LIMITE_NATURELLE')),
    zonage_affectation  text,
    regime_foncier      text
                        CHECK (regime_foncier IN ('PUBLIC', 'PRIVE', 'HQ',
                                                  'MIXTE', 'INDETERMINE')),
    nb_lots             integer,
    tension_kv          numeric(8,2),
    longueur_m          numeric(12,2),
    surface_m2          numeric(14,2),
    arrondissement      text,
    id_utg              text,
    geom                geometry(MultiPolygon, 2950) NOT NULL,
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_sections IS
  'Découpage de l''emprise en tronçons. Règle du mandat — chaque géométrie de '
  'zonage constitue un tronçon, et les propriétés privées forment des sections '
  'distinctes. Croisement affectation PUM 2050 par régime foncier par UTG.';

CREATE INDEX idx_t2h_sections_geom    ON uti.t2h_elec_sections USING GIST (geom);
CREATE INDEX idx_t2h_sections_emprise ON uti.t2h_elec_sections (id_emprise);
CREATE INDEX idx_t2h_sections_foncier ON uti.t2h_elec_sections (regime_foncier);


-- ============================================================================
-- SECTION 5 — EMPLACEMENTS (étape 5 du mandat)
-- ============================================================================

CREATE TABLE uti.t2h_elec_emplacements (
    id_emplacement      bigserial PRIMARY KEY,
    id_treevans         text UNIQUE,
    id_section          bigint NOT NULL REFERENCES uti.t2h_elec_sections(id_section),
    orientation         text NOT NULL
                        CHECK (orientation IN ('GAUCHE', 'DROITE',
                                               'AXIALE', 'PYLONE')),
    activite            text,
    activite_autorisee  boolean,
    accessible_prop     boolean,
    adresse             text,
    code_postal         text,
    surface_m2          numeric(14,2),
    perimetre_m         numeric(12,2),
    recherche           text,
    geom                geometry(MultiPolygon, 2950) NOT NULL,
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_emplacements IS
  'Plus petite représentation spatiale de l''UTI hydroélectrique. Analogue du '
  'parterre pair ou impair du routier, indexé sur l''orientation par rapport au '
  'centre-ligne. Ordre du mandat — orientation d''abord, puis activité, puis adresse.';

COMMENT ON COLUMN uti.t2h_elec_emplacements.accessible_prop IS
  'Exigence du mandat — le propriétaire doit pouvoir visualiser les parties de '
  'son lot qui ne lui sont pas accessibles.';

COMMENT ON COLUMN uti.t2h_elec_emplacements.code_postal IS
  'NULL attendu — SDA Postes Canada absent du corpus.';

CREATE INDEX idx_t2h_empl_geom    ON uti.t2h_elec_emplacements USING GIST (geom);
CREATE INDEX idx_t2h_empl_section ON uti.t2h_elec_emplacements (id_section);


-- ============================================================================
-- SECTION 6 — COHABITATION (étape 6 du mandat)
-- ============================================================================

CREATE TABLE uti.t2h_elec_rel_lots (
    id_relation         bigserial PRIMARY KEY,
    id_emplacement      bigint REFERENCES uti.t2h_elec_emplacements(id_emplacement),
    id_section          bigint REFERENCES uti.t2h_elec_sections(id_section),
    id_lot              text NOT NULL,
    code_utili          text,
    libelle_ut          text,
    type_relation       text NOT NULL
                        CHECK (type_relation IN ('ADOSSE', 'GREVE',
                                                 'INCLUS', 'CHEVAUCHANT')),
    surface_lot_m2      numeric(14,2),
    surface_grevee_m2   numeric(14,2),
    part_grevee_pct     numeric(5,2),
    proprietaire_type   text
                        CHECK (proprietaire_type IN ('PUBLIC', 'PRIVE',
                                                     'HQ', 'INDETERMINE')),
    active              boolean NOT NULL DEFAULT true,
    geom_intersection   geometry(MultiPolygon, 2950),
    date_maj            timestamptz NOT NULL DEFAULT now(),
    CHECK (id_emplacement IS NOT NULL OR id_section IS NOT NULL)
);

COMMENT ON TABLE uti.t2h_elec_rel_lots IS
  'Relations vers les lots cadastraux, activables et désactivables — exigence '
  'explicite du mandat. surface_grevee_m2 matérialise la parcelle réglementée : '
  'on n''intègre JAMAIS le lot riverain entier.';

CREATE INDEX idx_t2h_rel_lots_empl   ON uti.t2h_elec_rel_lots (id_emplacement);
CREATE INDEX idx_t2h_rel_lots_lot    ON uti.t2h_elec_rel_lots (id_lot);
CREATE INDEX idx_t2h_rel_lots_active ON uti.t2h_elec_rel_lots (active);
CREATE INDEX idx_t2h_rel_lots_geom   ON uti.t2h_elec_rel_lots USING GIST (geom_intersection);


CREATE TABLE uti.t2h_elec_incursions (
    id_incursion        bigserial PRIMARY KEY,
    id_emprise          bigint REFERENCES uti.t2h_elec_emprises(id_emprise),
    id_lot              text,
    type_incursion      text NOT NULL
                        CHECK (type_incursion IN ('LOT_DANS_EMPRISE',
                                                  'BATI_DANS_EMPRISE',
                                                  'CHEVAUCHEMENT_CADASTRAL',
                                                  'ENCASTREMENT')),
    surface_m2          numeric(14,2),
    traitement          text DEFAULT 'A_ARBITRER',
    geom                geometry(MultiPolygon, 2950) NOT NULL,
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.t2h_elec_incursions IS
  'Exceptions du mandat — lots se chevauchant ou s''encastrant dans la continuité '
  'de l''infrastructure.';

CREATE INDEX idx_t2h_incursions_geom ON uti.t2h_elec_incursions USING GIST (geom);


CREATE TABLE uti.t2h_elec_interferences (
    id_interference     bigserial PRIMARY KEY,
    id_emplacement      bigint REFERENCES uti.t2h_elec_emplacements(id_emplacement),
    id_section          bigint REFERENCES uti.t2h_elec_sections(id_section),
    famille             text NOT NULL
                        CHECK (famille IN ('NATURELLE', 'INFRASTRUCTURELLE')),
    type_actif          text NOT NULL,
    id_actif_source     text,
    conforme_degagement boolean,
    hauteur_m           numeric(6,2),
    distance_axe_m      numeric(8,2),
    geom                geometry(Geometry, 2950),
    date_maj            timestamptz NOT NULL DEFAULT now(),
    CHECK (id_emplacement IS NOT NULL OR id_section IS NOT NULL)
);

COMMENT ON TABLE uti.t2h_elec_interferences IS
  'Actifs urbains et naturels occupant ou interférant avec l''espace de l''UTI. '
  'Arbres, végétation, pistes cyclables, sentiers.';

CREATE INDEX idx_t2h_interf_geom ON uti.t2h_elec_interferences USING GIST (geom);
CREATE INDEX idx_t2h_interf_type ON uti.t2h_elec_interferences (type_actif);


CREATE TABLE uti.t2h_elec_conflits_voirie (
    id_conflit          bigserial PRIMARY KEY,
    id_corridor         bigint REFERENCES uti.t2h_elec_corridors(id_corridor),
    id_section          bigint REFERENCES uti.t2h_elec_sections(id_section),
    id_trc              text,
    type_conflit        text
                        CHECK (type_conflit IN ('SURPLOMB', 'CROISEMENT', 'LONGEMENT')),
    surface_m2          numeric(14,2),
    geom                geometry(Geometry, 2950),
    date_maj            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN uti.t2h_elec_conflits_voirie.id_trc IS
  'Clé d''attache du Livrable A. Jointure ATTRIBUTAIRE sur id_trc, jamais ST_Contains.';

CREATE INDEX idx_t2h_conflits_geom ON uti.t2h_elec_conflits_voirie USING GIST (geom);
CREATE INDEX idx_t2h_conflits_trc  ON uti.t2h_elec_conflits_voirie (id_trc);


-- ============================================================================
-- SECTION 7 — COUCHE MAÎTRESSE LIVRABLE (unique, tous niveaux)
-- ============================================================================

CREATE TABLE uti.couche_livrable_t2h (
    id_livrable          bigserial PRIMARY KEY,
    id_treevans          text UNIQUE NOT NULL,
    niveau               text NOT NULL
                         CHECK (niveau IN ('CORRIDOR', 'LIGNE', 'PYLONE', 'POSTE',
                                           'EMPRISE_AERIENNE', 'EMPRISE_SOL',
                                           'SECTION', 'EMPLACEMENT')),
    type_geom            text NOT NULL
                         CHECK (type_geom IN ('LINEAIRE', 'SURFACIQUE')),

    arrondissement       text,
    id_utg               text,

    corridor_id          bigint,
    corridor_ref         text,
    corridor_longueur_m  numeric(12,2),
    corridor_nb_lignes   integer,
    corridor_nb_pylones  integer,

    reseau               text,
    exploitant           text,
    tension_kv           numeric(8,2),
    tension_origine      text,

    emprise_ref          text,
    type_emprise         text,
    demi_largeur_m       numeric(6,2),
    origine_geom         text,
    statut_regle         text,
    licence_source       text,
    hauteur_veg_max_m    numeric(5,2),
    passage_acces_m      numeric(5,2),

    section_ref          text,
    zonage_affectation   text,
    regime_foncier       text,
    motif_decoupe        text,
    nb_lots              integer,

    orientation          text,
    activite             text,
    activite_autorisee   boolean,
    accessible_prop      boolean,
    adresse              text,
    code_postal          text,

    longueur_m           numeric(12,2),
    surface_m2           numeric(14,2),

    candidat_poste       boolean NOT NULL DEFAULT false,
    empreinte_fiable     boolean,
    chaine_complete      boolean NOT NULL DEFAULT false,
    note_limite          text,

    recherche            text,
    geom                 geometry(Geometry, 2950) NOT NULL,
    date_maj             timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE uti.couche_livrable_t2h IS
  'COUCHE MAÎTRESSE LIVRABLE unique. Tous les niveaux de la chaîne, chaque entité '
  'portant l''intégralité du contexte hérité de ses parents. Un clic donne la '
  'fiche complète. Dénormalisation assumée — NE PAS ÉDITER, régénérée à chaque '
  'exécution. La source de vérité reste les tables uti.t2h_elec_*.';

COMMENT ON COLUMN uti.couche_livrable_t2h.type_geom IS
  'Géométrie hétérogène. Corridors et lignes sont LINEAIRE, le reste SURFACIQUE. '
  'QGIS impose une symbologie par règles sur le champ niveau.';

CREATE INDEX idx_cl_t2h_geom      ON uti.couche_livrable_t2h USING GIST (geom);
CREATE INDEX idx_cl_t2h_niveau    ON uti.couche_livrable_t2h (niveau);
CREATE INDEX idx_cl_t2h_corridor  ON uti.couche_livrable_t2h (corridor_id);
CREATE INDEX idx_cl_t2h_recherche ON uti.couche_livrable_t2h (recherche);


-- ============================================================================
-- SECTION 8 — FONCTIONS UTILITAIRES
-- ============================================================================

-- Résolution du régime foncier depuis un code d'utilisation
CREATE OR REPLACE FUNCTION uti.f_regime_foncier(p_code text)
RETURNS text
LANGUAGE sql STABLE AS $fn$
    SELECT regime
    FROM uti.t2h_elec_foncier_regime
    WHERE (match_exact AND code_prefixe = p_code)
       OR (NOT match_exact AND p_code LIKE code_prefixe || '%')
    ORDER BY match_exact DESC, length(code_prefixe) DESC
    LIMIT 1
$fn$;

COMMENT ON FUNCTION uti.f_regime_foncier(text) IS
  'Résout un CODE_UTILI en régime. Règle exacte prioritaire, puis préfixe le plus '
  'long — ainsi 4590 PUBLIC l''emporte sur le préfixe 4 PRIVE.';


-- Extraction de la tension numérique depuis un libellé OSM
CREATE OR REPLACE FUNCTION uti.f_tension_num(p_txt text)
RETURNS numeric
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT max(v::numeric)
    FROM regexp_matches(coalesce(p_txt, ''), '(\d+)', 'g') AS m(arr),
         LATERAL unnest(arr) AS v
$fn$;

COMMENT ON FUNCTION uti.f_tension_num(text) IS
  'Extrait la tension la plus haute d''un libellé OSM. Un libellé multiple '
  'retourne la valeur supérieure, par prudence. Un libellé non numérique '
  'retourne NULL.';

-- ============================================================================
-- FIN 15_uti_hydroelectriques.sql
-- ============================================================================