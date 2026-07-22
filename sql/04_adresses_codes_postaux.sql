-- 04_adresses_codes_postaux.sql
-- Livrable A — étape 4 : rattachement des adresses aux tronçons
-- Colonnes raw.adresses : id_adresse, texte, addr_de, addr_a, specifique, geometry
--
-- CORRECTION 1 : chaque adresse est rattachée au SEUL tronçon le plus proche
-- (via LATERAL + ORDER BY distance), pour éviter le double-comptage d'une
-- même adresse sur plusieurs tronçons voisins dans les zones de chevauchement
-- de buffer (intersections, script 02 utilise un buffer de 20 m).
-- CORRECTION 2 : FILTER (WHERE ...) sur les array_agg pour éviter qu'un
-- LEFT JOIN sans correspondance ne produise un tableau {NULL} au lieu
-- d'un tableau vide.

-- Index spatial sur raw.adresses si absent (accélère ST_DWithin/ST_Distance)
CREATE INDEX IF NOT EXISTS idx_raw_adresses_geom ON raw.adresses USING GIST (geometry);

DROP TABLE IF EXISTS uti.adresses_troncon;
CREATE TABLE uti.adresses_troncon AS
SELECT
    a.id_adresse,
    a.texte,
    a.addr_de,
    a.addr_a,
    a.specifique,
    nearest.id_trc,
    nearest.dist_m
FROM raw.adresses a
JOIN LATERAL (
    SELECT tp.id_trc, ST_Distance(a.geometry, tp.geom) AS dist_m
    FROM uti.troncons_polygones tp
    WHERE ST_DWithin(a.geometry, tp.geom, 10)
    ORDER BY a.geometry <-> tp.geom
    LIMIT 1
) nearest ON TRUE;

CREATE INDEX idx_adresses_troncon_id ON uti.adresses_troncon (id_trc);

DROP TABLE IF EXISTS uti.troncons_adresses;
CREATE TABLE uti.troncons_adresses AS
SELECT
    tp.id_trc,
    tp.nom_rue,
    tp.deb_gch,
    tp.fin_gch,
    tp.deb_drt,
    tp.fin_drt,
    count(at.id_adresse) AS nb_adresses,
    array_agg(at.texte      ORDER BY at.texte)      FILTER (WHERE at.id_adresse IS NOT NULL) AS adresses_texte,
    array_agg(at.addr_de    ORDER BY at.addr_de)     FILTER (WHERE at.id_adresse IS NOT NULL) AS numeros_debut,
    array_agg(at.addr_a     ORDER BY at.addr_a)      FILTER (WHERE at.id_adresse IS NOT NULL) AS numeros_fin,
    array_agg(DISTINCT at.specifique ORDER BY at.specifique) FILTER (WHERE at.id_adresse IS NOT NULL) AS noms_voie
FROM uti.troncons_polygones tp
LEFT JOIN uti.adresses_troncon at
    ON at.id_trc = tp.id_trc
GROUP BY tp.id_trc, tp.nom_rue, tp.deb_gch, tp.fin_gch, tp.deb_drt, tp.fin_drt;

CREATE UNIQUE INDEX idx_troncons_adresses_id ON uti.troncons_adresses (id_trc);

-- Contrôle 1 : tronçons sans adresse rattachée
SELECT count(*) FROM uti.troncons_adresses WHERE nb_adresses = 0;

-- Contrôle 2 : vérifier qu'aucune adresse n'est comptée deux fois (doit retourner 0 lignes)
SELECT id_adresse, count(*) FROM uti.adresses_troncon GROUP BY id_adresse HAVING count(*) > 1;