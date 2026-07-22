-- 08_identifiants_treevans.sql
-- Étape 3 : génération des identifiants Treevans côté-de-rue
--
-- Format identifiant Treevans :
--   TRC-{ID_TRC}-G  → côté gauche  (impair selon convention MTL)
--   TRC-{ID_TRC}-D  → côté droit   (pair selon convention MTL)
--
-- Logique UTG : quand arr_gch ≠ arr_drt, les deux côtés appartiennent
-- à des UTG différentes → identifiants distincts avec UTG incluse.
--   Ex: TRC-1010001-G-VDN  (Verdun)
--       TRC-1010001-D-LAS  (LaSalle)

-- ── Étape 3a : ajouter les colonnes d'identifiant Treevans ────────────────
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS id_treevans    TEXT;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS arr_appartenance TEXT;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS utg_id          TEXT;

-- ── Étape 3b : renseigner les identifiants ─────────────────────────────────
UPDATE uti.parterres p
SET
    id_treevans = CASE
        -- Rue-limite UTG : côtés dans des arrondissements différents
        WHEN t.arr_gch IS DISTINCT FROM t.arr_drt THEN
            'TRC-' || t.id_trc::text || '-' ||
            CASE p.cote WHEN 'impair' THEN 'G' WHEN 'pair' THEN 'D' ELSE 'X' END ||
            '-' || UPPER(LEFT(
                CASE p.cote
                    WHEN 'impair' THEN COALESCE(t.arr_gch, 'INC')
                    WHEN 'pair'   THEN COALESCE(t.arr_drt, 'INC')
                    ELSE 'INC'
                END, 3))
        -- Rue intérieure : même arrondissement des deux côtés
        ELSE
            'TRC-' || t.id_trc::text || '-' ||
            CASE p.cote WHEN 'impair' THEN 'G' WHEN 'pair' THEN 'D' ELSE 'X' END
    END,
    arr_appartenance = CASE p.cote
        WHEN 'impair' THEN t.arr_gch
        WHEN 'pair'   THEN t.arr_drt
        ELSE NULL
    END,
    utg_id = CASE p.cote
        WHEN 'impair' THEN t.arr_gch
        WHEN 'pair'   THEN t.arr_drt
        ELSE NULL
    END
FROM uti.troncons_polygones t
WHERE p.id_trc = t.id_trc;

-- ── Étape 3c : index sur l'identifiant Treevans ────────────────────────────
CREATE INDEX IF NOT EXISTS idx_parterres_treevans ON uti.parterres (id_treevans);

-- ── Étape 3d : vue des rues-limites UTG (arr_gch ≠ arr_drt) ───────────────
DROP VIEW IF EXISTS uti.v_rues_limites_utg;
CREATE VIEW uti.v_rues_limites_utg AS
SELECT
    t.id_trc,
    t.nom_rue,
    t.arr_gch,
    t.arr_drt,
    t.axe AS geom
FROM uti.troncons_polygones t
WHERE t.arr_gch IS DISTINCT FROM t.arr_drt
  AND t.arr_gch IS NOT NULL
  AND t.arr_drt IS NOT NULL;

-- Contrôles :
-- SELECT count(*) FROM uti.parterres WHERE id_treevans IS NOT NULL;
-- SELECT count(*) FROM uti.v_rues_limites_utg;
-- SELECT id_treevans, cote, arr_appartenance FROM uti.parterres LIMIT 10;
-- SELECT id_trc, nom_rue, arr_gch, arr_drt FROM uti.v_rues_limites_utg LIMIT 10;