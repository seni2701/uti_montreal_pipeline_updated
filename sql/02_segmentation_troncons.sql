-- 02_segmentation_troncons.sql
-- Livrable A — étape 2 : polygones de tronçons
-- Chaque tronçon officiel (raw.reseau_routier, 1 ligne = 1 tronçon entre intersections)
-- est transformé en polygone par intersection avec le polygone de rue de même nom.
-- Colonnes clés : id_trc, odonyme, arr_gch, arr_drt, deb_gch, fin_gch, deb_drt, fin_drt
--
-- JOIN LATERAL avec selection du polygone a plus grande aire d'intersection,
-- pour eviter les doublons d'id_trc quand uti.rues_polygones contient
-- plusieurs lignes pour un meme nom_rue (segments non contigus).
--
-- DROP CASCADE necessaire car uti.v_rues_limites_utg depend de cette table.
-- La vue est recreee a la fin de ce script (memes colonnes, donc compatible).

DROP TABLE IF EXISTS uti.troncons_polygones CASCADE;

CREATE TABLE uti.troncons_polygones AS
SELECT
    r.id_trc,
    COALESCE(NULLIF(TRIM(r.odonyme), ''), 'SANS_NOM_' || r.id_trc::text) AS nom_rue,
    r.arr_gch,
    r.arr_drt,
    r.deb_gch,
    r.fin_gch,
    r.deb_drt,
    r.fin_drt,
    r.classe,
    r.sens_cir,
    r.geometry AS axe,
    inter.geom
FROM raw.reseau_routier r
JOIN LATERAL (
    SELECT
        ST_Multi(
            ST_Intersection(
                p.geom,
                ST_Buffer(r.geometry, 20, 'endcap=flat join=mitre')
            )
        )::geometry(MultiPolygon, 2950) AS geom,
        ST_Area(
            ST_Intersection(
                p.geom,
                ST_Buffer(r.geometry, 20, 'endcap=flat join=mitre')
            )
        ) AS aire_inter
    FROM uti.rues_polygones p
    WHERE p.nom_rue = COALESCE(NULLIF(TRIM(r.odonyme), ''), 'SANS_NOM_' || r.id_trc::text)
      AND ST_Intersects(p.geom, r.geometry)
    ORDER BY aire_inter DESC
    LIMIT 1
) inter ON TRUE
WHERE r.geometry IS NOT NULL
  AND inter.geom IS NOT NULL
  AND NOT ST_IsEmpty(inter.geom);

CREATE INDEX idx_troncons_polygones_geom ON uti.troncons_polygones USING GIST (geom);
CREATE INDEX idx_troncons_polygones_axe  ON uti.troncons_polygones USING GIST (axe);
CREATE UNIQUE INDEX idx_troncons_polygones_id ON uti.troncons_polygones (id_trc);

-- Recreation de la vue supprimee par le CASCADE ci-dessus
-- (definition recuperee via pg_get_viewdef avant correction)
CREATE VIEW uti.v_rues_limites_utg AS
SELECT id_trc,
       nom_rue,
       arr_gch,
       arr_drt,
       axe AS geom
FROM uti.troncons_polygones t
WHERE arr_gch IS DISTINCT FROM arr_drt
  AND arr_gch IS NOT NULL
  AND arr_drt IS NOT NULL;

-- Controle : geometries nulles/vides
SELECT count(*) FROM uti.troncons_polygones WHERE geom IS NULL OR ST_IsEmpty(geom);

-- Controle : confirmer qu'il n'y a plus de doublons d'id_trc
SELECT id_trc, count(*) FROM uti.troncons_polygones GROUP BY id_trc HAVING count(*) > 1;