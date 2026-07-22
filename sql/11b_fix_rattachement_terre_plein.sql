-- ============================================================================
-- 11b_fix_rattachement_terre_plein.sql
-- Correctif du script 11 : rattache aux terre-pleins les arbres restés
-- 'non_rattache', avec la vraie clé uti.terre_pleins.id_voirie (pas id_tp).
-- Convention CARTHAB : 11 n'est pas modifié ; ce correctif complète le résultat.
--
-- Colonnes réelles :
--   uti.terre_pleins(id_voirie, id_trc, geom)
--   uti.arbres(id_arbre PK, geom, id_trc, id_tp, methode_rattachement, distance_m)
-- ============================================================================

SET search_path = uti, raw, public;

WITH nearest AS (
    SELECT DISTINCT ON (a.id_arbre)
           a.id_arbre,
           t.id_voirie,
           t.id_trc                       AS tp_trc,
           ST_Distance(a.geom, t.geom)    AS dist
    FROM uti.arbres a
    JOIN uti.terre_pleins t
      ON ST_DWithin(a.geom, t.geom, 12)
    WHERE a.methode_rattachement = 'non_rattache'
      AND a.geom IS NOT NULL
    ORDER BY a.id_arbre, a.geom <-> t.geom
)
UPDATE uti.arbres a
   SET id_tp                = n.id_voirie,
       id_trc               = COALESCE(a.id_trc, n.tp_trc),
       methode_rattachement = CASE WHEN n.dist = 0 THEN 'contenu' ELSE 'proximite' END,
       distance_m           = n.dist
FROM nearest n
WHERE n.id_arbre = a.id_arbre;

-- Contrôle :
--   SELECT methode_rattachement, count(*) FROM uti.arbres GROUP BY 1;
--   SELECT count(*) FILTER (WHERE id_tp IS NOT NULL) AS sur_terre_plein FROM uti.arbres;
