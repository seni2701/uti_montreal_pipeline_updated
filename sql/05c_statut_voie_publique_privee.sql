-- 05c_statut_voie_publique_privee.sql
-- Ajout du statut public/prive sur les troncons et les parterres.
--
-- Sources :
--   raw.reseau_routier.CLASSE :
--     0 = Rue locale          -> public
--     1 = Collectrice         -> public
--     2 = Arterielle          -> public
--     3 = Autoroute           -> public
--     4 = Voie de service     -> public
--     5 = Ruelle              -> semi_public  (souvent priv\u00e9e ou partag\u00e9e)
--     6 = Sentier/acc\u00e8s pi\u00e9ton -> semi_public
--     7 = Voie cyclable       -> public
--     8 = Voie priv\u00e9e/acc\u00e8s   -> prive
--     9 = Ind\u00e9termin\u00e9         -> inconnu
--
--   raw.voirie_active.CATEGORIEC :
--     'Ruelle'                -> semi_public
--     'Autoroute'             -> public
--     'Bretelle'              -> public
--     'Rue'                   -> public

-- ── Etape 1 : ajouter colonnes sur troncons_polygones ─────────────────────
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS statut_voie  TEXT;
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS type_voie    TEXT;
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS usage_voie   TEXT;

-- ── Etape 2 : renseigner statut_voie depuis CLASSE ────────────────────────
UPDATE uti.troncons_polygones tp
SET
    statut_voie = CASE r.classe
        WHEN 0 THEN 'public'
        WHEN 1 THEN 'public'
        WHEN 2 THEN 'public'
        WHEN 3 THEN 'public'
        WHEN 4 THEN 'public'
        WHEN 5 THEN 'semi_public'
        WHEN 6 THEN 'semi_public'
        WHEN 7 THEN 'public'
        WHEN 8 THEN 'prive'
        WHEN 9 THEN 'inconnu'
        ELSE        'inconnu'
    END,
    type_voie = LOWER(TRIM(r.typ_voie)),
    usage_voie = CASE r.classe
        WHEN 3 THEN 'autoroute'
        WHEN 7 THEN 'cyclable'
        WHEN 5 THEN 'ruelle'
        WHEN 6 THEN 'pieton'
        WHEN 8 THEN 'prive'
        ELSE 'vehicule'
    END
FROM raw.reseau_routier r
WHERE tp.id_trc = r.id_trc;

-- ── Etape 3 : affiner avec voirie_active (CATEGORIEC plus precis) ─────────
-- Ruelles confirmees dans voirie_active -> semi_public
UPDATE uti.troncons_polygones tp
SET statut_voie = 'semi_public',
    usage_voie  = 'ruelle'
FROM raw.voirie_active va
WHERE ST_DWithin(tp.axe, va.geometry, 5)
  AND va.categoriec = 'Ruelle'
  AND tp.statut_voie != 'prive';

-- Voies privees confirmees via conditions ruelles
UPDATE uti.troncons_polygones tp
SET statut_voie = 'prive'
FROM raw.conditions_ruelles cr
WHERE ST_DWithin(tp.axe, cr.geometry, 5)
  AND tp.statut_voie = 'semi_public';

-- ── Etape 4 : propager sur les parterres ──────────────────────────────────
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS statut_voie TEXT;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS type_voie   TEXT;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS usage_voie  TEXT;

UPDATE uti.parterres p
SET statut_voie = tp.statut_voie,
    type_voie   = tp.type_voie,
    usage_voie  = tp.usage_voie
FROM uti.troncons_polygones tp
WHERE p.id_trc = tp.id_trc;

-- ── Etape 5 : index pour filtrage rapide ─────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_troncons_statut ON uti.troncons_polygones (statut_voie);
CREATE INDEX IF NOT EXISTS idx_parterres_statut ON uti.parterres (statut_voie);

-- ── Controles ─────────────────────────────────────────────────────────────
-- SELECT statut_voie, type_voie, count(*)
-- FROM uti.troncons_polygones
-- GROUP BY statut_voie, type_voie
-- ORDER BY statut_voie, count(*) DESC;
--
-- SELECT statut_voie, count(*) AS nb_troncons,
--        ROUND(count(*) * 100.0 / SUM(count(*)) OVER (), 1) AS pct
-- FROM uti.troncons_polygones
-- GROUP BY statut_voie ORDER BY nb_troncons DESC;
