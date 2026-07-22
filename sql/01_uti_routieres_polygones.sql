-- 01_uti_routieres_polygones.sql
-- Livrable A — étape 1 : polygones nominatifs de rue
-- Source géométrie : raw.reseau_routier (LineString, colonnes en MAJUSCULES après chargement)
-- UTG             : raw.limites_admin (colonnes : codeid, nom)
-- Nom de rue      : ODONYME (nom complet) ou NOM_VOIE (spécifique seul)

DROP TABLE IF EXISTS uti.rues_polygones CASCADE;

CREATE TABLE uti.rues_polygones AS
WITH troncons_utg AS (
    SELECT DISTINCT ON (r.id_trc)
        r.id_trc,
        COALESCE(NULLIF(TRIM(r.odonyme), ''), 'SANS_NOM_' || r.id_trc::text) AS nom_rue,
        g.codeid  AS id_utg,
        g.nom     AS nom_utg,
        r.geometry AS geom,
        r.deb_gch,
        r.fin_gch,
        r.deb_drt,
        r.fin_drt,
        r.arr_gch,
        r.arr_drt
    FROM raw.reseau_routier r
    JOIN raw.limites_admin g ON ST_Intersects(r.geometry, g.geometry)
    WHERE r.geometry IS NOT NULL
    ORDER BY r.id_trc, ST_Length(ST_Intersection(r.geometry, g.geometry)) DESC
)
SELECT
    nom_rue,
    id_utg,
    nom_utg,
    ST_Multi(
        ST_Buffer(ST_Union(geom), 15, 'endcap=flat join=round')
    )::geometry(MultiPolygon, 2950) AS geom
FROM troncons_utg
GROUP BY nom_rue, id_utg, nom_utg;

CREATE INDEX idx_rues_polygones_geom ON uti.rues_polygones USING GIST (geom);
CREATE INDEX idx_rues_polygones_nom  ON uti.rues_polygones (nom_rue);

-- Contrôle : SELECT count(*), count(DISTINCT nom_rue) FROM uti.rues_polygones;