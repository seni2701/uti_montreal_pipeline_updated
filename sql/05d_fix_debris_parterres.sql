-- 05d_fix_debris_parterres.sql
-- Correctif CARTHAB (fichier suffixe) — NE MODIFIE PAS 03_emplacements_parterres.sql
-- NI 05b_fix_parterres_surface_nulle.sql
-- ---------------------------------------------------------------------------
-- Objet : eliminer les debris (petits fragments) dans uti.parterres et
--         garantir UNE geometrie propre par (id_trc, cote), de facon
--         uniforme sur l'ensemble du jeu de donnees (aucune exception
--         par rue).
--
-- Cause reelle :
--   03 stocke un ROW PAR FRAGMENT ST_Dump issu de ST_Split, sans jamais les
--   dissoudre. Des lors que troncons_polygones a une forme concave (courbe,
--   encoche laissee par les clips 02b/02c), ST_Split produit plusieurs petits
--   polygones disjoints sur un meme cote -> ce sont les "debris" observes,
--   plus frequents sur les rues a geometrie complexe (courbes, intersections
--   en biais), mais le probleme est generique, pas specifique a une rue.
--   05b aggrave parfois la situation en reinjectant des demi-polygones bruts
--   (moitie du troncon complet, sans redecoupe) pour les cas de surface nulle.
--
-- Strategie (appliquee identiquement partout, aucun seuil different par rue) :
--   1. Dissoudre (ST_Union) tous les fragments d'un meme (id_trc, cote).
--   2. Re-eclater le resultat (ST_Dump) : un multipolygone dissous peut encore
--      contenir plusieurs parties disjointes si le troncon est reellement
--      discontinu a cet endroit (ex. echancrure profonde d'un bati).
--   3. Ne garder que les parties dont l'aire depasse SEUIL_AIRE_M2 (debris
--      elimine). Les parties legitimes mais petites (entrees cochères etc.)
--      ne devraient normalement pas descendre sous ce seuil ; ajuster au besoin.
--   4. Reconstituer un (multi)polygone final unique par (id_trc, cote).
--
-- Chaine : ce fichier se place entre 05b et 07 dans le runner
--   (03_ < 05b < 05d < 07_). Rejouer ensuite 07 puis couche_combinee_uti.py.
--
-- Non destructif : l'ancienne table est conservee sous uti.parterres_avant_05d.
-- Runner uniquement (SQLAlchemy) — SQL plat, aucun bloc DO/plpgsql, aucune
-- meta-commande psql.
--
-- CORRECTIF : les ALTER INDEX en etape C sont maintenant qualifies avec le
-- schema uti. Sans ce prefixe, ALTER INDEX resout le nom via search_path,
-- qui n'inclut pas uti dans cet environnement -> UndefinedTable au rename,
-- meme si l'index existe bel et bien dans uti (les index heritent toujours
-- du schema de leur table, quel que soit le search_path au CREATE INDEX).
-- ===========================================================================

-- ── Parametre unique, applique uniformement ─────────────────────────────────
-- SEUIL_AIRE_M2 : aire minimale (m2) sous laquelle un fragment est considere
-- comme un debris et elimine. 2.0 m2 est un defaut prudent (plus petit qu'une
-- entree cochere standard, assez grand pour capter les eclats de precision
-- geometrique). Ajuster ici seulement, jamais au cas par cas dans les donnees.
-- (Remplacer la valeur 2.0 ci-dessous si un autre seuil est retenu.)

-- ── Etape A : sauvegarde non destructive de l'etat courant ──────────────────
DROP TABLE IF EXISTS uti.parterres_avant_05d;

CREATE TABLE uti.parterres_avant_05d AS
SELECT * FROM uti.parterres;

-- ── Etape B : dissolution + filtrage debris + reconstruction ────────────────
DROP TABLE IF EXISTS uti.parterres_nettoyes CASCADE;

CREATE TABLE uti.parterres_nettoyes AS
WITH dissous AS (
    SELECT id_trc, cote, ST_Union(geom) AS geom_brut
    FROM uti.parterres
    WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
      AND cote IN ('pair', 'impair')
    GROUP BY id_trc, cote
),
eclate AS (
    SELECT id_trc, cote, (ST_Dump(geom_brut)).geom AS morceau
    FROM dissous
),
filtre AS (
    SELECT id_trc, cote, morceau, ST_Area(morceau) AS aire
    FROM eclate
    WHERE ST_Area(morceau) >= 2.0   -- SEUIL_AIRE_M2 : debris elimine sous ce seuil
)
SELECT
    id_trc,
    cote,
    1 AS demi_id,
    ST_Multi(ST_Union(morceau))::geometry(MultiPolygon, 2950) AS geom,
    ROUND(SUM(aire)::numeric, 2) AS surface_m2,
    ROUND(ST_Perimeter(ST_Union(morceau))::numeric, 2) AS perimetre_m,
    FALSE AS terre_plein
FROM filtre
GROUP BY id_trc, cote;

CREATE INDEX idx_parterres_nettoyes_geom  ON uti.parterres_nettoyes USING GIST (geom);
CREATE INDEX idx_parterres_nettoyes_tronc ON uti.parterres_nettoyes (id_trc);

-- ── Etape C : bascule (remplace uti.parterres par la version nettoyee) ──────
DROP TABLE IF EXISTS uti.parterres CASCADE;
ALTER TABLE uti.parterres_nettoyes RENAME TO parterres;
ALTER INDEX uti.idx_parterres_nettoyes_geom  RENAME TO idx_parterres_geom;
ALTER INDEX uti.idx_parterres_nettoyes_tronc RENAME TO idx_parterres_tronc;

-- ── CONTROLES (le runner n'affiche pas les SELECT : lire dans QGIS) ──────────
-- CONTROLE 1 : reduction du nombre de rows (fragments -> 1 par id_trc+cote).
-- Le compte "apres" doit etre <= nb distinct de (id_trc, cote) dans l'avant.
SELECT
    (SELECT count(*) FROM uti.parterres_avant_05d) AS rows_avant,
    (SELECT count(*) FROM uti.parterres)            AS rows_apres,
    (SELECT count(DISTINCT (id_trc, cote)) FROM uti.parterres_avant_05d
        WHERE cote IN ('pair','impair'))             AS paires_id_trc_cote_distinctes;

-- CONTROLE 2 : aire totale de debris elimine (doit rester une faible
-- fraction de l'aire totale — sinon le seuil est probablement trop eleve).
SELECT
    ROUND((SELECT SUM(ST_Area(geom)) FROM uti.parterres_avant_05d
           WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom))::numeric, 1) AS aire_avant_m2,
    ROUND((SELECT SUM(surface_m2) FROM uti.parterres)::numeric, 1)        AS aire_apres_m2;

-- CONTROLE 3 : parterres 'indetermine' laisses de cote (cote non pair/impair).
-- A examiner manuellement si non nul : signale un axe degenere en amont.
SELECT count(*) AS parterres_indetermines_exclus
FROM uti.parterres_avant_05d
WHERE cote = 'indetermine';

-- ── Nettoyage (decommenter une fois le controle valide en production) ───────
-- DROP TABLE IF EXISTS uti.parterres_avant_05d;