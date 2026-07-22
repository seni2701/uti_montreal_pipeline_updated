-- =====================================================================
-- 14f_fix_arr_troncons.sql
-- Corrige arr_gch / arr_drt de uti.troncons_polygones, restes en 'N/A'
-- (bruts de raw.reseau_routier) alors que 09b a deja resolu les
-- arrondissements sur uti.parterres.arr_appartenance.
--
-- Constat (qualifier_na_adresses.py) :
--   - 10 240 troncons ont un cote arr = 'N/A' ; 10 168 ont les DEUX cotes 'N/A'
--   - ce ne sont PAS des bordures de territoire : 1re/2e/43e/55e Avenue (Lachine...)
--   - 09b a corrige les PARTERRES mais jamais troncons_polygones.arr_gch/arr_drt
--
-- Strategie : propager l'arrondissement du PARTERRE (deja resolu par 09b)
-- vers le cote correspondant du tronçon. Mapping (cf 09b etape 3) :
--   cote 'impair' -> G (arr_gch)   |   cote 'pair' -> D (arr_drt)
-- On ne re-fait PAS de jointure spatiale : on reutilise le resultat valide de 09b.
--
-- Convention CARTHAB : fichier suffixe, ne modifie PAS 09b.
-- Runner SQLAlchemy : une instruction par ligne (pas de bloc DO).
-- =====================================================================

-- A CONFIRMER avant execution :
--   * mapping cote->G/D : 'impair'=G=arr_gch, 'pair'=D=arr_drt (cf 09b etape 3)
--   * la valeur "resolue" a propager = arr_appartenance != 'N/A' ET != 'INCONNU'
--     (on ne propage PAS 'INCONNU' vers arr_gch/arr_drt : on garde 'N/A' pour
--      les vraies bordures / non resolus, plus honnete pour le livrable)

-- Trace : sauvegarde des valeurs d'origine avant correction (auditabilite)
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS arr_gch_src text;
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS arr_drt_src text;
UPDATE uti.troncons_polygones
SET arr_gch_src = arr_gch, arr_drt_src = arr_drt
WHERE (arr_gch = 'N/A' OR arr_drt = 'N/A')
  AND arr_gch_src IS NULL AND arr_drt_src IS NULL;

-- [1] Cote GAUCHE (arr_gch) <- parterre impair resolu
UPDATE uti.troncons_polygones t
SET arr_gch = p.arr_appartenance
FROM uti.parterres p
WHERE p.id_trc = t.id_trc
  AND p.cote = 'impair'
  AND t.arr_gch = 'N/A'
  AND p.arr_appartenance IS NOT NULL
  AND p.arr_appartenance NOT IN ('N/A', 'INCONNU');

-- [2] Cote DROIT (arr_drt) <- parterre pair resolu
UPDATE uti.troncons_polygones t
SET arr_drt = p.arr_appartenance
FROM uti.parterres p
WHERE p.id_trc = t.id_trc
  AND p.cote = 'pair'
  AND t.arr_drt = 'N/A'
  AND p.arr_appartenance IS NOT NULL
  AND p.arr_appartenance NOT IN ('N/A', 'INCONNU');

-- La vue v_rues_limites_utg lit directement troncons_polygones : elle refletera
-- automatiquement les arr_gch/arr_drt corriges, aucune action requise sur la vue.

-- Controles (a lire via qualifier_na_adresses.py ou un client SQL) :
--   -- combien de N/A restants par cote ?
--   SELECT count(*) FILTER (WHERE arr_gch='N/A') AS gch_na,
--          count(*) FILTER (WHERE arr_drt='N/A') AS drt_na,
--          count(*) FILTER (WHERE arr_gch='N/A' AND arr_drt='N/A') AS deux_na
--   FROM uti.troncons_polygones;
--
--   -- vraies limites UTG-A apres correction (sans N/A) :
--   SELECT count(*) FILTER (WHERE arr_gch<>'N/A' AND arr_drt<>'N/A'
--                             AND arr_gch<>arr_drt) AS vraies_limites
--   FROM uti.v_rues_limites_utg;
