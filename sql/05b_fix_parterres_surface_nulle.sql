-- 05b_fix_parterres_surface_nulle.sql
-- Correction des 309 parterres avec surface nulle.
--
-- Cause : ST_Split echoue sur les polygones de troncons complexes
-- (courbes, geometries degenerees) -> demi_id produit mais surface = NULL.
--
-- Strategie : approximation par division de la surface du troncon par 2.
-- C'est la valeur la plus coherente disponible sans redecoupe geometrique.

-- Etape 1 : corriger surface_m2 et perimetre_m par approximation
UPDATE uti.parterres p
SET
    surface_m2  = ROUND((ST_Area(t.geom) / 2.0)::numeric, 2),
    perimetre_m = ROUND(ST_Perimeter(t.geom)::numeric, 2)
FROM uti.troncons_polygones t
WHERE p.id_trc = t.id_trc
  AND (p.surface_m2 IS NULL OR p.surface_m2 <= 0)
  AND t.geom IS NOT NULL;

-- Etape 2 : corriger aussi la geometrie nulle si present
-- (remplacer par la moitie approximative du polygone de troncon)
UPDATE uti.parterres p
SET geom = ST_Multi(
    CASE p.cote
        WHEN 'impair' THEN
            ST_GeometryN(
                ST_Split(
                    t.geom,
                    ST_SetSRID(ST_MakeLine(
                        ST_MakePoint(
                            ST_X(ST_StartPoint(t.axe)),
                            ST_Y(ST_StartPoint(t.axe))
                        ),
                        ST_MakePoint(
                            ST_X(ST_EndPoint(t.axe)),
                            ST_Y(ST_EndPoint(t.axe))
                        )
                    ), 2950)
                ),
                1
            )
        ELSE
            ST_GeometryN(
                ST_Split(
                    t.geom,
                    ST_SetSRID(ST_MakeLine(
                        ST_MakePoint(
                            ST_X(ST_StartPoint(t.axe)),
                            ST_Y(ST_StartPoint(t.axe))
                        ),
                        ST_MakePoint(
                            ST_X(ST_EndPoint(t.axe)),
                            ST_Y(ST_EndPoint(t.axe))
                        )
                    ), 2950)
                ),
                2
            )
    END
)::geometry(MultiPolygon, 2950)
FROM uti.troncons_polygones t
WHERE p.id_trc = t.id_trc
  AND (p.geom IS NULL OR ST_IsEmpty(p.geom))
  AND t.geom IS NOT NULL
  AND t.axe IS NOT NULL
  AND ST_Length(t.axe) > 0;

-- Etape 3 : pour les cas ou la geometrie est encore NULL apres tentative
-- (troncons trop degeneres), assigner le polygone complet du troncon
UPDATE uti.parterres p
SET
    geom        = ST_Multi(t.geom)::geometry(MultiPolygon, 2950),
    surface_m2  = ROUND((ST_Area(t.geom) / 2.0)::numeric, 2),
    perimetre_m = ROUND(ST_Perimeter(t.geom)::numeric, 2)
FROM uti.troncons_polygones t
WHERE p.id_trc = t.id_trc
  AND (p.geom IS NULL OR ST_IsEmpty(p.geom))
  AND t.geom IS NOT NULL;

-- Controle final
-- SELECT count(*) AS restants_surface_nulle
-- FROM uti.parterres WHERE surface_m2 IS NULL OR surface_m2 <= 0;
-- SELECT count(*) AS restants_geom_nulle
-- FROM uti.parterres WHERE geom IS NULL OR ST_IsEmpty(geom);
