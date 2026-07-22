-- ============================================================================
-- 13b_fix_activation_geocodage.sql
-- Correctif du script 13 : rebranche les deux blocs neutralisés, avec les
-- vrais noms de colonnes confirmés par information_schema.
--   A) Activation des relations lots  -> colonne réelle : actif (+ date_activation)
--   B) Taux de géocodage              -> proxy dist_m (adresses_troncon n'a pas de geom)
-- Convention CARTHAB : 13 n'est pas modifié ; ce correctif le complète.
-- ============================================================================

SET search_path = uti, raw, public;

-- ---------------------------------------------------------------------------
-- A) Activation par défaut des relations directes (le rapport indiquait 0).
--    'inclus' et 'chevauche' = adossement direct -> actives ; 'proximité' inactive.
--    date_activation horodatée pour les relations activées.
-- ---------------------------------------------------------------------------
UPDATE uti.troncons_lots
   SET actif           = (type_relation IN ('inclus','chevauche')),
       date_activation = CASE WHEN type_relation IN ('inclus','chevauche')
                              THEN now() END;

-- ---------------------------------------------------------------------------
-- B) Taux de géocodage par tronçon.
--    adresses_troncon n'a pas de géométrie ; dist_m renseigné = adresse
--    positionnée géographiquement (proxy de géocodage — à valider).
-- ---------------------------------------------------------------------------
ALTER TABLE uti.troncons_adresses ADD COLUMN IF NOT EXISTS taux_geocodage numeric;

WITH g AS (
    SELECT id_trc,
           count(*)::numeric                                   AS total,
           count(*) FILTER (WHERE dist_m IS NOT NULL)::numeric  AS geocode
    FROM uti.adresses_troncon
    GROUP BY id_trc
)
UPDATE uti.troncons_adresses ta
   SET taux_geocodage = CASE WHEN g.total > 0 THEN round(g.geocode / g.total, 3) ELSE 0 END
  FROM g
 WHERE g.id_trc = ta.id_trc;

-- Contrôles :
--   SELECT actif, count(*) FROM uti.troncons_lots GROUP BY 1;
--   SELECT profil_acces, actif, count(*) FROM uti.troncons_lots GROUP BY 1,2 ORDER BY 1,2;
--   SELECT round(avg(taux_geocodage),3) AS taux_moyen,
--          count(*) FILTER (WHERE taux_geocodage = 0) AS troncons_sans_geocode
--   FROM uti.troncons_adresses;
