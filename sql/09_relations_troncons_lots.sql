-- 10_relations_troncons_lots.sql
-- Étape 4 : relations tronçon ↔ lots cadastraux (activable/désactivable)
--
-- Principe Treevans : un propriétaire de lot peut "activer" la relation
-- pour voir les données de son parterre de tronçon. La relation est
-- stockée comme une table de jointure avec un flag actif/inactif.
--
-- Un lot est "adossé" à un parterre si son bord touche ou chevauche
-- le parterre à moins de 2 m (tolérance cadastrale).

-- ── Étape 4a : table de jointure tronçon ↔ lots ───────────────────────────
DROP TABLE IF EXISTS uti.troncons_lots;

CREATE TABLE uti.troncons_lots AS
SELECT DISTINCT ON (p.id_treevans, c.g_no_lot)
    -- Identifiants
    p.id_treevans,
    p.id_trc,
    p.cote,
    p.arr_appartenance,
    -- Lot cadastral
    c.g_no_lot          AS no_lot,
    c.g_co_type_        AS type_lot,
    c.g_nm_circn        AS arrondissement_lot,
    ROUND(ST_Area(c.geometry)::numeric, 2) AS surface_lot_m2,
    -- Nature de la relation spatiale
    CASE
        WHEN ST_Within(c.geometry, p.geom)        THEN 'inclus'
        WHEN ST_Touches(c.geometry, p.geom)       THEN 'adjacent'
        WHEN ST_Intersects(c.geometry, p.geom)    THEN 'chevauche'
        ELSE 'proximit\u00e9'
    END AS type_relation,
    ROUND(ST_Distance(c.geometry, p.geom)::numeric, 2) AS distance_m,
    -- Flag activable/désactivable (FALSE par défaut = non activé)
    FALSE               AS actif,
    NOW()               AS date_creation,
    NULL::timestamptz   AS date_activation,
    -- Géométrie du lot (pour visualisation)
    c.geometry          AS geom_lot
FROM uti.parterres p
JOIN raw.cadastre c
    ON ST_DWithin(c.geometry, p.geom, 2)   -- tolérance 2 m
WHERE
    p.id_treevans IS NOT NULL
    AND c.geometry IS NOT NULL
    -- Exclure les très grands lots (plans d'eau, parcs régionaux)
    AND ST_Area(c.geometry) < 200000
ORDER BY p.id_treevans, c.g_no_lot, ST_Distance(c.geometry, p.geom);

-- ── Index ──────────────────────────────────────────────────────────────────
CREATE INDEX idx_troncons_lots_treevans ON uti.troncons_lots (id_treevans);
CREATE INDEX idx_troncons_lots_trc      ON uti.troncons_lots (id_trc);
CREATE INDEX idx_troncons_lots_lot      ON uti.troncons_lots (no_lot);
CREATE INDEX idx_troncons_lots_actif    ON uti.troncons_lots (actif);
CREATE INDEX idx_troncons_lots_geom     ON uti.troncons_lots USING GIST (geom_lot);

-- ── Étape 4b : fonction pour activer/désactiver une relation ───────────────
CREATE OR REPLACE FUNCTION uti.activer_relation(
    p_id_treevans TEXT,
    p_no_lot      TEXT,
    p_activer     BOOLEAN DEFAULT TRUE
)
RETURNS TEXT AS $$
DECLARE
    nb_modif INTEGER;
BEGIN
    UPDATE uti.troncons_lots
    SET actif          = p_activer,
        date_activation = CASE WHEN p_activer THEN NOW() ELSE NULL END
    WHERE id_treevans = p_id_treevans
      AND no_lot      = p_no_lot;

    GET DIAGNOSTICS nb_modif = ROW_COUNT;

    IF nb_modif = 0 THEN
        RETURN 'Aucune relation trouvée pour ' || p_id_treevans || ' / lot ' || p_no_lot;
    END IF;
    RETURN nb_modif::text || ' relation(s) ' ||
           CASE WHEN p_activer THEN 'activée(s)' ELSE 'désactivée(s)' END;
END;
$$ LANGUAGE plpgsql;

-- ── Étape 4c : vue des relations actives ───────────────────────────────────
DROP VIEW IF EXISTS uti.v_relations_actives;
CREATE VIEW uti.v_relations_actives AS
SELECT
    tl.id_treevans,
    tl.id_trc,
    tl.cote,
    tl.no_lot,
    tl.arrondissement_lot,
    tl.surface_lot_m2,
    tl.type_relation,
    tl.date_activation,
    p.geom AS geom_parterre,
    tl.geom_lot
FROM uti.troncons_lots tl
JOIN uti.parterres p ON p.id_treevans = tl.id_treevans
WHERE tl.actif = TRUE;

-- Contrôles :
-- SELECT type_relation, count(*) FROM uti.troncons_lots GROUP BY type_relation;
-- SELECT count(*) FROM uti.troncons_lots;
-- SELECT uti.activer_relation('TRC-1010001-G', '3 322 337', TRUE);
-- SELECT * FROM uti.v_relations_actives LIMIT 5;
