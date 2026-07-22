-- 09b_fix_arr_appartenance.sql
-- Correction des parterres avec arr_appartenance = NULL ou 'N/A'.
--
-- Cause : certains troncons ont arr_gch et arr_drt NULL dans raw.reseau_routier
-- (troncons hors ile, voies privees, bretelles d'autoroute non municipales).
--
-- Strategie de correction en cascade :
--   1. Jointure spatiale avec raw.limites_admin (le plus fiable)
--   2. Si toujours NULL : recuperer depuis les troncons voisins (meme rue)
--   3. Regenerer id_treevans pour les parterres resolus (etapes 1-2)
--   4. Si toujours NULL : marquer 'INCONNU' (tracable pour la livraison)
--   5. Regenerer id_treevans pour les parterres INCONNU (coherence du format)

-- Etape 1 : jointure spatiale avec les limites administratives
-- CORRECTION : la sous-requete referencait un alias p2 inexistant.
-- La logique voulue est une sous-requete correlee sur p (la ligne en
-- cours de mise a jour), pas une jointure avec une seconde instance
-- de parterres.
UPDATE uti.parterres p
SET
    arr_appartenance = la.nom,
    utg_id           = la.codeid
FROM raw.limites_admin la
WHERE (p.arr_appartenance IS NULL OR p.arr_appartenance = 'N/A')
  AND ST_Intersects(p.geom, la.geometry)
  AND ST_Area(ST_Intersection(p.geom, la.geometry))
      = (
          SELECT MAX(ST_Area(ST_Intersection(p.geom, la2.geometry)))
          FROM raw.limites_admin la2
          WHERE ST_Intersects(p.geom, la2.geometry)
        );

-- Etape 2 : propager depuis les troncons voisins de la meme rue
UPDATE uti.parterres p
SET
    arr_appartenance = voisin.arr_appartenance,
    utg_id           = voisin.utg_id
FROM (
    SELECT DISTINCT ON (p2.id_trc, p2.cote)
        p2.id_trc,
        p2.cote,
        p_ref.arr_appartenance,
        p_ref.utg_id
    FROM uti.parterres p2
    JOIN uti.troncons_polygones t2  ON t2.id_trc  = p2.id_trc
    JOIN uti.troncons_polygones t_v ON t_v.nom_rue = t2.nom_rue
                                   AND t_v.id_trc != t2.id_trc
    JOIN uti.parterres p_ref        ON p_ref.id_trc = t_v.id_trc
                                   AND p_ref.cote   = p2.cote
    WHERE (p2.arr_appartenance IS NULL OR p2.arr_appartenance = 'N/A')
      AND p_ref.arr_appartenance IS NOT NULL
      AND p_ref.arr_appartenance != 'N/A'
    ORDER BY p2.id_trc, p2.cote, ST_Distance(t2.axe, t_v.axe)
) voisin
WHERE p.id_trc = voisin.id_trc
  AND p.cote   = voisin.cote
  AND (p.arr_appartenance IS NULL OR p.arr_appartenance = 'N/A');

-- Etape 3 : regenerer id_treevans avec le bon arrondissement
-- (parterres resolus aux etapes 1-2)
UPDATE uti.parterres p
SET id_treevans =
    CASE
        WHEN t.arr_gch IS DISTINCT FROM t.arr_drt
             AND t.arr_gch IS NOT NULL
             AND t.arr_drt IS NOT NULL
        THEN
            'TRC-' || t.id_trc::text || '-' ||
            CASE p.cote WHEN 'impair' THEN 'G' WHEN 'pair' THEN 'D' ELSE 'X' END ||
            '-' || UPPER(LEFT(p.arr_appartenance, 3))
        ELSE
            'TRC-' || t.id_trc::text || '-' ||
            CASE p.cote WHEN 'impair' THEN 'G' WHEN 'pair' THEN 'D' ELSE 'X' END
    END
FROM uti.troncons_polygones t
WHERE p.id_trc = t.id_trc
  AND p.arr_appartenance IS NOT NULL
  AND p.arr_appartenance != 'N/A';

-- Etape 4 : marquer les cas restants comme INCONNU (tracabilite livraison)
UPDATE uti.parterres
SET arr_appartenance = 'INCONNU',
    utg_id           = 'INCONNU'
WHERE arr_appartenance IS NULL OR arr_appartenance = 'N/A';

-- Etape 5 : regenerer id_treevans pour les parterres INCONNU, afin que
-- le format reste coherent et tracable (suffixe -INC explicite plutot
-- qu'un id_treevans perime issu d'un calcul anterieur a ce script)
UPDATE uti.parterres p
SET id_treevans =
    'TRC-' || t.id_trc::text || '-' ||
    CASE p.cote WHEN 'impair' THEN 'G' WHEN 'pair' THEN 'D' ELSE 'X' END ||
    '-INC'
FROM uti.troncons_polygones t
WHERE p.id_trc = t.id_trc
  AND p.arr_appartenance = 'INCONNU';

-- Controles finaux :
-- SELECT arr_appartenance, count(*) FROM uti.parterres
-- GROUP BY arr_appartenance ORDER BY count(*) DESC LIMIT 10;
--
-- SELECT count(*) AS nb_inconnus FROM uti.parterres
-- WHERE arr_appartenance = 'INCONNU';
--
-- SELECT count(*) AS nb_na FROM uti.parterres
-- WHERE arr_appartenance = 'N/A';
--
-- Controle supplementaire : confirmer qu'aucun parterre n'a un
-- id_treevans incoherent avec son statut arr_appartenance
-- SELECT id_trc, cote, arr_appartenance, id_treevans FROM uti.parterres
-- WHERE arr_appartenance = 'INCONNU' AND id_treevans NOT LIKE '%-INC';