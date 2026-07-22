-- 13c_provision_nb_adresses.sql
-- Correctif CARTHAB (fichier suffixe) — NE MODIFIE NI 13 NI 14a.
-- ---------------------------------------------------------------------------
-- Objet : provisionner uti.troncons_polygones.nb_adresses, dependance de
--         14a_diagnostic_invalidites.sql.
--
-- Cause : 02 recree troncons_polygones a neuf (DROP CASCADE), sans nb_adresses ;
--         aucun script de 02 a 13b ne l'ajoute a cette table. La colonne
--         n'existait donc que par heritage d'un etat anterieur. Une
--         reconstruction propre depuis 02 la fait disparaitre, et 14a echoue.
--
-- Source : uti.troncons_adresses (agregee par 04, 1 ligne/troncon), la meme
--          d'ou couche_combinee_uti.py tire deja nb_adresses. Cle : id_trc.
--
-- Placement : entre 13b et 14a (13b_ < 13c_ < 14a_). Rejouable et non
-- destructif (ADD COLUMN IF NOT EXISTS + UPDATE). SQL plat, runner uniquement.
-- ===========================================================================

-- Etape 1 : garantir la colonne
ALTER TABLE uti.troncons_polygones
    ADD COLUMN IF NOT EXISTS nb_adresses integer;

-- Etape 2 : renseigner depuis la table d'adresses agregee
-- (cast en text par securite si les types de cle different).
UPDATE uti.troncons_polygones t
SET nb_adresses = COALESCE(a.nb_adresses, 0)
FROM uti.troncons_adresses a
WHERE a.id_trc::text = t.id_trc::text;

-- Etape 3 : tout troncon sans correspondance d'adresse = 0 (et non NULL),
-- pour que le test de coherence de 14a (nb_adresses = 0) soit valide.
UPDATE uti.troncons_polygones
SET nb_adresses = 0
WHERE nb_adresses IS NULL;

-- Controle (non affiche par le runner ; lisible dans QGIS) :
-- repartition des troncons selon qu'ils portent ou non des adresses.
SELECT
    count(*)                                   AS n_troncons,
    count(*) FILTER (WHERE nb_adresses > 0)    AS avec_adresses,
    count(*) FILTER (WHERE nb_adresses = 0)    AS sans_adresses
FROM uti.troncons_polygones;
