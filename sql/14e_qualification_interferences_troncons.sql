-- =====================================================================
-- 14e_qualification.sql   (LECTURE SEULE — produit la donnee de decision)
-- POINTS 2 et 3 — a QUALIFIER avant toute correction (decision metier).
-- Ne modifie RIEN : ces deux points demandent un arbitrage humain, pas un
-- UPDATE a l'aveugle. Ce script fournit les chiffres pour trancher.
-- A lire via un client SQL ou en l'adaptant dans diagnostic_uti.py.
-- =====================================================================

-- ---------------------------------------------------------------------
-- POINT 3 — Interferences ponctuelles sans id_trc (3 255, diagnostic [F2])
-- Question : vide LEGITIME (hors rayon de rattachement) vs RATE de rattachement ?
-- On mesure la distance au troncon le plus proche (elargi a 50 m).
-- ---------------------------------------------------------------------

-- 3a) Repartition par tranche de distance : combien auraient DU se rattacher ?
SELECT
  CASE
    WHEN d IS NULL       THEN 'aucun troncon < 50 m (vide legitime)'
    WHEN d <= 15         THEN '<= 15 m (RATE probable : dans le rayon)'
    WHEN d <= 30         THEN '15-30 m (limite)'
    ELSE                      '30-50 m (probablement legitime)'
  END AS tranche,
  count(*) AS n
FROM (
  SELECT i.id_interf,
         (SELECT min(ST_Distance(i.geom, t.geom))
          FROM uti.troncons_polygones t
          WHERE ST_DWithin(i.geom, t.geom, 50)) AS d
  FROM uti.interferences_troncon i
  WHERE i.id_trc IS NULL AND i.categorie <> 'chantier'
) s
GROUP BY tranche
ORDER BY tranche;

-- 3b) Ventilation par categorie (collision vs signalisation) des non-rattaches
SELECT categorie, count(*) AS n_sans_id_trc
FROM uti.interferences_troncon
WHERE id_trc IS NULL AND categorie <> 'chantier'
GROUP BY categorie ORDER BY n_sans_id_trc DESC;


-- ---------------------------------------------------------------------
-- POINT 2 — Troncons nb_adresses=0 avec plage civique definie (5 018, [F1])
-- Question : plage HERITEE du reseau source (normal) vs RATE de geocodage ?
-- Indice : un tronçon avec plage ET taux_geocodage NULL = pas d'adresse
-- geocodee rattachee malgre une plage -> candidat "rate".
-- ---------------------------------------------------------------------

-- 2a) Croisement plage civique x presence de geocodage
SELECT
  CASE WHEN taux_geocodage IS NULL THEN 'sans geocodage (candidat rate)'
       ELSE 'avec geocodage' END AS etat_geocodage,
  count(*) AS n
FROM uti.troncons_adresses
WHERE nb_adresses = 0
  AND ( COALESCE(deb_gch,0) <> 0 OR COALESCE(fin_gch,0) <> 0
     OR COALESCE(deb_drt,0) <> 0 OR COALESCE(fin_drt,0) <> 0 )
GROUP BY etat_geocodage ORDER BY n DESC;

-- 2b) Echantillon des 20 cas pour inspection manuelle (type Beausejour)
SELECT id_trc, nom_rue, deb_gch, fin_gch, deb_drt, fin_drt, taux_geocodage
FROM uti.troncons_adresses
WHERE nb_adresses = 0
  AND ( COALESCE(deb_gch,0) <> 0 OR COALESCE(fin_gch,0) <> 0
     OR COALESCE(deb_drt,0) <> 0 OR COALESCE(fin_drt,0) <> 0 )
ORDER BY id_trc
LIMIT 20;
