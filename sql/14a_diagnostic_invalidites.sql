-- =====================================================================
-- 14a_diagnostic_invalidites.sql
-- LECTURE SEULE — aucun ALTER / UPDATE / DELETE.
-- Rôle : GATE de la phase 0. Doit etre execute et lu AVANT 14b.
-- Convention CARTHAB : fichier suffixe, ne modifie aucun script numerote.
-- Runner SQLAlchemy : valeurs litterales uniquement (pas de \set, pas de :var).
-- =====================================================================

-- ---------------------------------------------------------------------
-- A CONFIRMER AVANT EXECUTION (adapter aux noms reels du schema uti) :
--   * Tables            : uti.rues_polygones, uti.troncons_polygones, uti.parterres,
--                         uti.terre_pleins, uti.composantes_voirie,
--                         uti.interferences_troncon, uti.arbres,
--                         uti.rues_limites_utg
--   * Colonne geometrie : geom (SRID 2950) sur chacune
--   * Cle de jointure    : uti.parterres.id_trc  =  uti.troncons_polygones.id_trc
--                          (caster si l'un est real et l'autre integer)
--   * Colonnes troncon   : nb_adresses, deb_gch, fin_gch, deb_drt, fin_drt,
--                          taux_geocodage, code_postal
--   * Colonnes parterre  : cote, flag_surface_aberrante
--   * Colonnes limite UTG : arr_gch, arr_drt
-- Si un nom differe, corriger ici AVANT de lancer. Ne rien supposer.
-- ---------------------------------------------------------------------


-- [A] Inventaire global des invalidites geometriques par couche ---------
SELECT 'rues_polygones'      AS couche, count(*) AS n,
       count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS n_invalides
FROM uti.rues_polygones
UNION ALL SELECT 'troncons',           count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.troncons_polygones
UNION ALL SELECT 'parterres',          count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.parterres
UNION ALL SELECT 'terre_pleins',       count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.terre_pleins
UNION ALL SELECT 'composantes_voirie', count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.composantes_voirie
UNION ALL SELECT 'interferences',      count(*), count(*) FILTER (WHERE NOT ST_IsValid(geom)) FROM uti.interferences_troncon
ORDER BY n_invalides DESC;


-- [B] Nature des invalidites (motif GEOS) sur les couches surfaciques ---
SELECT 'parterres' AS couche, reason(ST_IsValidDetail(geom)) AS motif, count(*) AS n
FROM uti.parterres      WHERE NOT ST_IsValid(geom) GROUP BY reason(ST_IsValidDetail(geom))
UNION ALL
SELECT 'troncons',      reason(ST_IsValidDetail(geom)), count(*)
FROM uti.troncons_polygones       WHERE NOT ST_IsValid(geom) GROUP BY reason(ST_IsValidDetail(geom))
UNION ALL
SELECT 'rues_polygones', reason(ST_IsValidDetail(geom)), count(*)
FROM uti.rues_polygones WHERE NOT ST_IsValid(geom) GROUP BY reason(ST_IsValidDetail(geom))
ORDER BY couche, n DESC;


-- [C] *** GATE CAUSE RACINE *** -----------------------------------------
-- Les parterres invalides heritent-ils de troncons invalides ?
--   ko_sous_troncon_ok  domine -> defaut cree a la decoupe des parterres
--                                 (ST_MakeValid aval acceptable)
--   ko_sous_troncon_ko  domine -> defaut herite -> ASSAINIR LES TRONCONS
--                                 PUIS REGENERER parterres/terre-pleins
SELECT
  count(*) FILTER (WHERE NOT ST_IsValid(p.geom))                            AS parterres_ko,
  count(*) FILTER (WHERE NOT ST_IsValid(p.geom) AND NOT ST_IsValid(t.geom)) AS ko_sous_troncon_ko,
  count(*) FILTER (WHERE NOT ST_IsValid(p.geom) AND     ST_IsValid(t.geom)) AS ko_sous_troncon_ok
FROM uti.parterres p
JOIN uti.troncons_polygones  t ON t.id_trc = p.id_trc;

-- [C bis] Asymetrie pair/impair (le defaut frappe-t-il un cote ?) --------
SELECT p.cote,
       count(*)                                        AS n_total,
       count(*) FILTER (WHERE NOT ST_IsValid(p.geom))  AS n_invalides,
       round(100.0 * count(*) FILTER (WHERE NOT ST_IsValid(p.geom)) / count(*), 1) AS pct
FROM uti.parterres p
GROUP BY p.cote
ORDER BY pct DESC;


-- [D] Invariant de reference AVANT correction (a re-tester apres 14b) ----
SELECT
  (SELECT round(sum(ST_Area(geom))::numeric, 2) FROM uti.troncons_polygones)  AS aire_troncons,
  (SELECT round(sum(ST_Area(geom))::numeric, 2) FROM uti.parterres) AS aire_parterres,
  (SELECT count(*) FROM uti.troncons_polygones)  AS n_troncons,
  (SELECT count(*) FROM uti.parterres) AS n_parterres;
-- Attendu (socle valide) : aires egales ~ 183 232 624 m2 ; 47 980 / 99 962.


-- [E] Parterres degeneres (slivers) : valides != pertinents --------------
SELECT
  count(*) FILTER (WHERE ST_Area(geom) < 5)                                  AS slivers_sous_5m2,
  count(*) FILTER (WHERE ST_Area(geom) < 5 AND NOT ST_IsValid(geom))         AS slivers_invalides,
  0::bigint       AS slivers_deja_flagges
FROM uti.parterres;


-- [F] QUALIFICATIONS ATTRIBUTAIRES (a trancher avant de statuer) ---------

-- [F1] Troncons nb_adresses = 0 avec plage civique definie (les ~5 018)
SELECT count(*) AS n_incoherents
FROM uti.troncons_polygones
WHERE nb_adresses = 0
  AND ( COALESCE(deb_gch,0) <> 0 OR COALESCE(fin_gch,0) <> 0
     OR COALESCE(deb_drt,0) <> 0 OR COALESCE(fin_drt,0) <> 0 );

-- [F2] Interferences ponctuelles non rattachees (les ~3 255)
--      vide legitime (> rayon de rattachement) vs raté a recuperer
SELECT i.id_interf, i.categorie,
       round(min(ST_Distance(i.geom, t.geom))::numeric, 2) AS dist_troncon_le_plus_proche
FROM uti.interferences_troncon i
LEFT JOIN uti.troncons_polygones t ON ST_DWithin(i.geom, t.geom, 50)
WHERE i.id_trc IS NULL AND i.categorie <> 'chantier'
GROUP BY i.id_interf, i.categorie
ORDER BY dist_troncon_le_plus_proche NULLS LAST;

-- [F3] Arbres hors emprise MTM8 (anomalie xmax ~ 5 000 000)
-- NB : bornes indicatives. Les VALIDER en les derivant de l'etendue reelle :
--      SELECT ST_Extent(geom) FROM uti.utg;
SELECT count(*) AS n_hors_emprise
FROM uti.arbres
WHERE ST_X(geom) NOT BETWEEN 260000 AND 320000
   OR ST_Y(geom) NOT BETWEEN 5010000 AND 5075000;

-- [F4] Coherence des rues-limites UTG : une limite separe 2 UTG-A distinctes
SELECT count(*)                                                  AS total,
       count(*) FILTER (WHERE arr_gch = arr_drt)                 AS faux_limites,
       count(*) FILTER (WHERE arr_gch IS NULL OR arr_drt IS NULL) AS cote_indetermine
FROM uti.rues_limites_utg;



