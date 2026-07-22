-- ============================================================================
-- 13_enrichissement_colonnes.sql
-- Livrable A — Enrichissement des TABLES EXISTANTES (sans les recréer).
-- Respecte la convention CARTHAB : aucun script numéroté validé n'est modifié ;
-- on ajoute des colonnes via ALTER ... ADD COLUMN IF NOT EXISTS puis UPDATE.
--
-- Dépendances : 10 (composantes_voirie, pistes_cyclables) et 11 (arbres)
-- doivent avoir été exécutés pour les agrégats correspondants.
--
-- ⚠️ À VALIDER :
--   - Présence d'une colonne id_trc sur uti.parterres (sinon dériver de id_treevans).
--   - Table/colonne portant la surface du tronçon (ici ST_Area(geom) par défaut).
--   - Sortie de 05c_statut_voie_publique_privee : nom de la table/colonne de statut.
--   - Source des codes postaux (le champ doit exister sur les adresses chargées).
--   - Règles d'accès par profil : valeurs par défaut ci-dessous à arbitrer avec le métier.
-- ============================================================================

SET search_path = uti, raw, public;

-- ===========================================================================
-- A) uti.parterres — emplacements
-- ===========================================================================
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS rang_surface           integer;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS nb_arbres              integer DEFAULT 0;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS presence_trottoir      boolean DEFAULT FALSE;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS presence_saillie       boolean DEFAULT FALSE;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS presence_piste_cyclable boolean DEFAULT FALSE;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS flag_multi_parterre    boolean DEFAULT FALSE;
ALTER TABLE uti.parterres ADD COLUMN IF NOT EXISTS statut_public_prive    text;

-- A.1  Classement des emplacements du tronçon, du plus petit au plus grand (mandat).
--      (parterres seuls ici ; pour inclure les terre-pleins, faire l'UNION en commentaire.)
WITH r AS (
    SELECT id_treevans,
           row_number() OVER (PARTITION BY id_trc ORDER BY ST_Area(geom) ASC) AS rang
    FROM uti.parterres
)
UPDATE uti.parterres p
   SET rang_surface = r.rang
  FROM r
 WHERE r.id_treevans = p.id_treevans;

-- A.2  Nombre d'arbres par emplacement (issu de 11).
UPDATE uti.parterres SET nb_arbres = 0;
UPDATE uti.parterres p
   SET nb_arbres = a.n
  FROM (
        SELECT id_treevans, count(*) AS n
        FROM uti.arbres
        WHERE id_treevans IS NOT NULL
        GROUP BY id_treevans
       ) a
 WHERE a.id_treevans = p.id_treevans;

-- A.3  Présence de composantes infrastructurelles (issu de 10).
UPDATE uti.parterres p
   SET presence_trottoir = EXISTS (
           SELECT 1 FROM uti.composantes_voirie c
           WHERE c.id_treevans = p.id_treevans
             AND c.type_composante = 'trottoir'
       ),
       presence_saillie = EXISTS (
           SELECT 1 FROM uti.composantes_voirie c
           WHERE c.id_treevans = p.id_treevans
             AND c.saillie ILIKE 'oui'          -- valeurs reelles : 'Oui' / 'Non'
       );

-- piste cyclable : rattachée au tronçon (donc aux deux parterres)
UPDATE uti.parterres p
   SET presence_piste_cyclable = EXISTS (
           SELECT 1 FROM uti.pistes_cyclables pc WHERE pc.id_trc = p.id_trc
       );

-- A.4  Drapeau d'anomalie : tronçons à plus de 2 parterres (3 830 cas au rapport).
UPDATE uti.parterres SET flag_multi_parterre = FALSE;
UPDATE uti.parterres p
   SET flag_multi_parterre = TRUE
 WHERE p.id_trc IN (
        SELECT id_trc FROM uti.parterres GROUP BY id_trc HAVING count(*) > 2
       );

-- A.5  Statut public/privé de l'emplacement — DÉPEND de 05c.
--      Active la règle « si l'UTI portant l'adresse est publique → afficher
--      tronçon + UTI ». Décommenter en pointant vers la sortie réelle de 05c.
-- UPDATE uti.parterres p
--    SET statut_public_prive = v.statut          -- 'public' | 'prive'
--   FROM uti.voie_statut v                         -- ⚠️ table/colonne à confirmer
--  WHERE v.id_trc = p.id_trc;

-- ===========================================================================
-- B) uti.troncons_polygones — qualité géométrique
-- ===========================================================================
ALTER TABLE uti.troncons_polygones ADD COLUMN IF NOT EXISTS flag_surface_aberrante boolean;

-- 2 211 tronçons > 10 000 m² au rapport : on les marque pour revue.
UPDATE uti.troncons_polygones
   SET flag_surface_aberrante = (ST_Area(geom) > 10000);

-- ===========================================================================
-- C) uti.troncons_adresses — couverture adresses et codes postaux
-- ===========================================================================
ALTER TABLE uti.troncons_adresses ADD COLUMN IF NOT EXISTS taux_geocodage numeric;
ALTER TABLE uti.troncons_adresses ADD COLUMN IF NOT EXISTS code_postal    text;

-- C.1  Taux de géocodage = adresses géolocalisées / adresses rattachées au tronçon.
--      NEUTRALISÉ : schéma de uti.adresses_troncon à confirmer (colonne geom/id_trc).
--      Colonne taux_geocodage conservée (NULL) ; restaurer le calcul ci-dessous
--      une fois les noms de colonnes validés.
-- WITH g AS (
--     SELECT id_trc,
--            count(*)::numeric                                   AS total,
--            count(*) FILTER (WHERE geom IS NOT NULL)::numeric    AS geocode
--     FROM uti.adresses_troncon
--     GROUP BY id_trc
-- )
-- UPDATE uti.troncons_adresses ta
--    SET taux_geocodage = CASE WHEN g.total > 0 THEN round(g.geocode / g.total, 3) ELSE 0 END
--   FROM g
--  WHERE g.id_trc = ta.id_trc;

-- C.2  Code postal dominant du tronçon — seulement si la source le fournit.
-- UPDATE uti.troncons_adresses ta
--    SET code_postal = m.cp
--   FROM (
--         SELECT id_trc,
--                mode() WITHIN GROUP (ORDER BY code_postal) AS cp  -- ⚠️ champ à confirmer
--         FROM uti.adresses_troncon
--         WHERE code_postal IS NOT NULL
--         GROUP BY id_trc
--        ) m
--  WHERE m.id_trc = ta.id_trc;

-- ===========================================================================
-- D) uti.troncons_lots — profils d'accès et activation des relations
-- ===========================================================================
ALTER TABLE uti.troncons_lots ADD COLUMN IF NOT EXISTS profil_acces text;

-- D.1  Profil destinataire par défaut selon le type de relation.
--      Le Gestionnaire voit tout (géré au niveau applicatif) ; on cible ici
--      Propriétaire (lot adossé direct) et Bénéficiaire (proximité).
UPDATE uti.troncons_lots
   SET profil_acces = CASE
        WHEN type_relation IN ('inclus','chevauche') THEN 'proprietaire'
        WHEN type_relation ILIKE 'proximit%'         THEN 'beneficiaire'
        ELSE 'gestionnaire'
   END;

-- D.2  Activation par défaut des relations directes (le rapport indique 0 active).
--      NEUTRALISÉ : la colonne d'activation de uti.troncons_lots porte un autre
--      nom (à confirmer). Restaurer avec le vrai nom une fois le schéma connu.
-- UPDATE uti.troncons_lots
--    SET active = (type_relation IN ('inclus','chevauche'));

-- ===========================================================================
-- E) Index sur les nouveaux drapeaux fréquemment filtrés
-- ===========================================================================
CREATE INDEX IF NOT EXISTS idx_parterres_rang        ON uti.parterres (id_trc, rang_surface);
CREATE INDEX IF NOT EXISTS idx_parterres_flag_multi  ON uti.parterres (flag_multi_parterre) WHERE flag_multi_parterre;
CREATE INDEX IF NOT EXISTS idx_troncons_flag_surface ON uti.troncons_polygones (flag_surface_aberrante) WHERE flag_surface_aberrante;
CREATE INDEX IF NOT EXISTS idx_lots_profil           ON uti.troncons_lots (profil_acces);

-- Contrôles rapides :
--   SELECT count(*) FROM uti.parterres WHERE flag_multi_parterre;
--   SELECT count(*) FROM uti.troncons_polygones WHERE flag_surface_aberrante;
--   SELECT profil_acces, count(*) FROM uti.troncons_lots GROUP BY 1;
--   SELECT count(*) FROM uti.troncons_lots WHERE active;   -- doit passer de 0 à >0