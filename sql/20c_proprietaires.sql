-- ============================================================================
-- 20c_proprietaires.sql
-- LIVRABLE D V8 — PAIR / IMPAIR STRICT + EMPRISE DE CHUTE
-- ----------------------------------------------------------------------------
-- Règle stricte :
--   • une seule entité PAIR par ligne;
--   • une seule entité IMPAIR par ligne;
--   • aucun découpage géométrique par lot cadastral;
--   • les lots et régimes fonciers restent uniquement des attributs agrégés.
--
-- Résultat attendu avec 160 lignes : 320 entités.
-- ============================================================================


-- ============================================================================
-- 0 — NETTOYAGE
-- ============================================================================

DROP VIEW IF EXISTS uti.v_t2h_elec_sol_controle CASCADE;
DROP TABLE IF EXISTS uti.couche_livrable_t2h_sol CASCADE;


-- ============================================================================
-- 1 — CONSTRUCTION DES DEUX CÔTÉS, PUIS DISSOLUTION STRICTE
-- ============================================================================

CREATE TABLE uti.couche_livrable_t2h_sol AS
WITH lignes_sol AS (
    SELECT
        e.id_emprise,
        e.id_ligne,
        e.id_regle,
        l.reseau,
        U&'Hydro-Qu\00E9bec'::text AS exploitant,
        COALESCE(e.tension_kv, l.tension_kv) AS tension_kv,
        e.demi_largeur_m,
        e.surface_m2 AS emprise_sol_m2_source,
        d.geom::geometry(LineString, 2950) AS geom_brin
    FROM uti.t2h_elec_emprises e
    JOIN uti.t2h_elec_lignes l
      ON l.id_ligne = e.id_ligne
    CROSS JOIN LATERAL ST_Dump(
        ST_LineMerge(
            ST_CollectionExtract(
                ST_MakeValid(l.geom_sol),
                2
            )
        )
    ) d
    WHERE e.type_emprise = 'SOL'
      AND e.demi_largeur_m IS NOT NULL
      AND e.demi_largeur_m > 0
      AND l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
      AND GeometryType(d.geom) = 'LINESTRING'
),
buffers_bruts AS (
    SELECT
        id_emprise,
        id_ligne,
        id_regle,
        reseau,
        exploitant,
        tension_kv,
        demi_largeur_m,
        emprise_sol_m2_source,
        'IMPAIR'::text AS emplacement,
        ST_Buffer(
            geom_brin,
            demi_largeur_m,
            'side=left endcap=flat join=mitre'
        ) AS geom
    FROM lignes_sol

    UNION ALL

    SELECT
        id_emprise,
        id_ligne,
        id_regle,
        reseau,
        exploitant,
        tension_kv,
        demi_largeur_m,
        emprise_sol_m2_source,
        'PAIR'::text AS emplacement,
        ST_Buffer(
            geom_brin,
            demi_largeur_m,
            'side=right endcap=flat join=mitre'
        ) AS geom
    FROM lignes_sol
),
cotes_dissous AS (
    SELECT
        id_ligne,
        MAX(id_regle) AS id_regle,
        MAX(reseau) AS reseau,
        MAX(exploitant) AS exploitant,
        MAX(tension_kv) AS tension_kv,
        MAX(demi_largeur_m) AS demi_largeur_m,
        MAX(emprise_sol_m2_source) AS emprise_sol_m2_source,
        emplacement,
        ST_Multi(
            ST_CollectionExtract(
                ST_UnaryUnion(
                    ST_Collect(
                        ST_MakeValid(geom)
                    )
                ),
                3
            )
        )::geometry(MultiPolygon, 2950) AS geom
    FROM buffers_bruts
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_Area(geom) > 0.5
    GROUP BY id_ligne, emplacement
),
cadastre_prepare AS (
    SELECT
        id_uev::text AS id_uev,
        uti.f_regime_foncier(code_utili) AS regime_foncier,
        ST_Multi(
            ST_CollectionExtract(
                ST_MakeValid(geometry),
                3
            )
        )::geometry(MultiPolygon, 2950) AS geom
    FROM raw.role_foncier
    WHERE geometry IS NOT NULL
),
attributs_cadastre AS (
    SELECT
        c.id_ligne,
        c.emplacement,

        string_agg(
            DISTINCT r.id_uev,
            ', '
            ORDER BY r.id_uev
        ) FILTER (
            WHERE r.id_uev IS NOT NULL
        ) AS numeros_lots,

        CASE
            WHEN COUNT(DISTINCT r.regime_foncier)
                 FILTER (WHERE r.regime_foncier IS NOT NULL) = 0
                THEN 'NON CLASSE'
            WHEN COUNT(DISTINCT r.regime_foncier)
                 FILTER (WHERE r.regime_foncier IS NOT NULL) = 1
                THEN MIN(r.regime_foncier)
                     FILTER (WHERE r.regime_foncier IS NOT NULL)
            ELSE 'MIXTE'
        END AS regime_foncier

    FROM cotes_dissous c
    LEFT JOIN cadastre_prepare r
      ON ST_Intersects(c.geom, r.geom)
    GROUP BY c.id_ligne, c.emplacement
),
union_cadastre AS (
    SELECT
        ST_UnaryUnion(
            ST_Collect(geom)
        ) AS geom
    FROM cadastre_prepare
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
),
mesures AS (
    SELECT
        c.*,
        COALESCE(a.numeros_lots, 'HORS CADASTRE') AS numeros_lots,
        COALESCE(a.regime_foncier, 'NON CLASSE') AS regime_foncier,

        CASE
            WHEN ST_Area(c.geom) = 0
                THEN 0::numeric
            ELSE ROUND(
                (
                    100.0
                    * ST_Area(
                        ST_Intersection(
                            c.geom,
                            u.geom
                        )
                    )
                    / ST_Area(c.geom)
                )::numeric,
                2
            )
        END AS pct_couverture_cadastre

    FROM cotes_dissous c
    LEFT JOIN attributs_cadastre a
      ON a.id_ligne = c.id_ligne
     AND a.emplacement = c.emplacement
    CROSS JOIN union_cadastre u
),
final_base AS (
    SELECT
        ROW_NUMBER() OVER (
            ORDER BY id_ligne, emplacement
        )::bigint AS id,

        id_ligne,
        reseau,
        exploitant,
        tension_kv,

        ROUND(demi_largeur_m::numeric, 2)
            AS largeur_buffer_m,

        ROUND((demi_largeur_m * 2.0)::numeric, 2)
            AS largeur_emprise_totale_m,

        NULL::numeric AS longueur_ligne_sol_m,

        emplacement,
        numeros_lots,
        regime_foncier,

        CASE
            WHEN pct_couverture_cadastre >= 99.5
                THEN 'CADASTRE'
            WHEN pct_couverture_cadastre >= 80
                THEN 'BORDURE_CADASTRE'
            WHEN pct_couverture_cadastre > 0
                THEN 'COUVERTURE_PARTIELLE'
            ELSE 'HORS_COUVERTURE_CADASTRALE'
        END::text AS statut_cadastre,

        ROUND(ST_Area(geom)::numeric, 2) AS surface_m2,

        ROUND(emprise_sol_m2_source::numeric, 2)
            AS emprise_sol_m2,

        NULL::numeric AS empreinte_ligne_sol_m2,
        NULL::numeric AS hauteur_ligne_m,
        NULL::numeric AS hauteur_vegetation_max_m,

        -- Surface totale de la zone potentielle de chute de la ligne.
        -- Calculée plus bas uniquement pour le réseau TRANSPORT.
        NULL::numeric AS emprise_chute_m2,

        geom

    FROM mesures
    WHERE geom IS NOT NULL
      AND NOT ST_IsEmpty(geom)
      AND ST_Area(geom) > 0.5
)
SELECT *
FROM final_base;


ALTER TABLE uti.couche_livrable_t2h_sol
    ADD CONSTRAINT couche_livrable_t2h_sol_pk PRIMARY KEY (id);

CREATE INDEX idx_couche_livrable_t2h_sol_geom
    ON uti.couche_livrable_t2h_sol
    USING gist (geom);

CREATE UNIQUE INDEX idx_couche_livrable_t2h_sol_ligne_cote
    ON uti.couche_livrable_t2h_sol (id_ligne, emplacement);


-- ============================================================================
-- 2 — ENRICHISSEMENT DES COLONNES MÉTIER
-- ============================================================================


UPDATE uti.couche_livrable_t2h_sol f
SET longueur_ligne_sol_m = x.longueur_m
FROM (
    SELECT
        id_ligne,
        ROUND(ST_Length(geom_sol)::numeric, 2) AS longueur_m
    FROM uti.t2h_elec_lignes
    WHERE geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(geom_sol)
) x
WHERE x.id_ligne = f.id_ligne;


UPDATE uti.couche_livrable_t2h_sol f
SET empreinte_ligne_sol_m2 = x.surface_m2
FROM (
    SELECT
        id_ligne,
        ROUND(
            ST_Area(
                ST_UnaryUnion(
                    ST_Collect(geom)
                )
            )::numeric,
            2
        ) AS surface_m2
    FROM uti.couche_livrable_t2h_sol
    GROUP BY id_ligne
) x
WHERE x.id_ligne = f.id_ligne;


UPDATE uti.couche_livrable_t2h_sol f
SET hauteur_vegetation_max_m = x.hauteur_m
FROM (
    SELECT
        e.id_ligne,
        ROUND(MAX(g.hauteur_veg_max_m)::numeric, 2) AS hauteur_m
    FROM uti.t2h_elec_emprises e
    JOIN uti.t2h_elec_regles_degagement g
      ON g.id_regle = e.id_regle
    WHERE e.type_emprise = 'SOL'
    GROUP BY e.id_ligne
) x
WHERE x.id_ligne = f.id_ligne;


-- Recherche automatique d'une hauteur réellement disponible.
-- Aucune valeur n'est inventée.
DO $hauteur_ligne$
DECLARE
    col_hauteur text;
BEGIN
    SELECT c.column_name
    INTO col_hauteur
    FROM information_schema.columns c
    WHERE c.table_schema = 'uti'
      AND c.table_name = 't2h_elec_lignes'
      AND lower(c.column_name) IN (
          'hauteur_ligne_m',
          'hauteur_m',
          'hauteur_support_m',
          'hauteur_pylone_m',
          'hauteur_totale_m',
          'height_m',
          'height',
          'hauteur'
      )
    ORDER BY array_position(
        ARRAY[
            'hauteur_ligne_m',
            'hauteur_m',
            'hauteur_support_m',
            'hauteur_pylone_m',
            'hauteur_totale_m',
            'height_m',
            'height',
            'hauteur'
        ],
        lower(c.column_name)
    )
    LIMIT 1;

    IF col_hauteur IS NOT NULL THEN
        EXECUTE format(
            $sql$
            UPDATE uti.couche_livrable_t2h_sol f
            SET hauteur_ligne_m = x.hauteur_m
            FROM (
                SELECT
                    id_ligne,
                    ROUND(
                        MAX(
                            CASE
                                WHEN NULLIF(
                                    regexp_replace(
                                        replace(%1$I::text, ',', '.'),
                                        '[^0-9.-]+',
                                        '',
                                        'g'
                                    ),
                                    ''
                                ) ~ '^-?[0-9]+([.][0-9]+)?$'
                                THEN NULLIF(
                                    regexp_replace(
                                        replace(%1$I::text, ',', '.'),
                                        '[^0-9.-]+',
                                        '',
                                        'g'
                                    ),
                                    ''
                                )::numeric
                                ELSE NULL
                            END
                        ),
                        2
                    ) AS hauteur_m
                FROM uti.t2h_elec_lignes
                GROUP BY id_ligne
            ) x
            WHERE x.id_ligne = f.id_ligne
            $sql$,
            col_hauteur
        );

        RAISE NOTICE
            'hauteur_ligne_m lue depuis uti.t2h_elec_lignes.%',
            col_hauteur;
        RETURN;
    END IF;

    SELECT c.column_name
    INTO col_hauteur
    FROM information_schema.columns c
    WHERE c.table_schema = 'uti'
      AND c.table_name = 't2h_elec_pylones'
      AND lower(c.column_name) IN (
          'hauteur_m',
          'hauteur_support_m',
          'hauteur_pylone_m',
          'hauteur_totale_m',
          'height_m',
          'height',
          'hauteur'
      )
    ORDER BY array_position(
        ARRAY[
            'hauteur_m',
            'hauteur_support_m',
            'hauteur_pylone_m',
            'hauteur_totale_m',
            'height_m',
            'height',
            'hauteur'
        ],
        lower(c.column_name)
    )
    LIMIT 1;

    IF col_hauteur IS NOT NULL THEN
        EXECUTE format(
            $sql$
            UPDATE uti.couche_livrable_t2h_sol f
            SET hauteur_ligne_m = x.hauteur_m
            FROM (
                SELECT
                    id_ligne,
                    ROUND(
                        MAX(
                            CASE
                                WHEN NULLIF(
                                    regexp_replace(
                                        replace(%1$I::text, ',', '.'),
                                        '[^0-9.-]+',
                                        '',
                                        'g'
                                    ),
                                    ''
                                ) ~ '^-?[0-9]+([.][0-9]+)?$'
                                THEN NULLIF(
                                    regexp_replace(
                                        replace(%1$I::text, ',', '.'),
                                        '[^0-9.-]+',
                                        '',
                                        'g'
                                    ),
                                    ''
                                )::numeric
                                ELSE NULL
                            END
                        ),
                        2
                    ) AS hauteur_m
                FROM uti.t2h_elec_pylones
                WHERE id_ligne IS NOT NULL
                GROUP BY id_ligne
            ) x
            WHERE x.id_ligne = f.id_ligne
            $sql$,
            col_hauteur
        );

        RAISE NOTICE
            'hauteur_ligne_m lue depuis uti.t2h_elec_pylones.%',
            col_hauteur;
        RETURN;
    END IF;

    RAISE NOTICE
        'Aucune hauteur de ligne disponible : hauteur_ligne_m reste NULL.';
END
$hauteur_ligne$;


-- ============================================================================
-- EMPRISE DE CHUTE DES LIGNES ÉLECTRIQUES DE TRANSPORT
-- ============================================================================
-- Hypothèse conservatrice :
-- la distance latérale potentielle de chute est égale à hauteur_ligne_m.
--
-- La colonne emprise_chute_m2 contient donc la surface du buffer total
-- autour de geom_sol, avec un rayon égal à hauteur_ligne_m.
--
-- Si aucune hauteur fiable n'existe dans les données sources, la valeur
-- reste NULL. Aucune hauteur n'est inventée.

UPDATE uti.couche_livrable_t2h_sol f
SET emprise_chute_m2 = x.emprise_chute_m2
FROM (
    SELECT
        f2.id_ligne,
        ROUND(
            ST_Area(
                ST_Buffer(
                    l.geom_sol,
                    MAX(f2.hauteur_ligne_m),
                    'endcap=flat join=mitre'
                )
            )::numeric,
            2
        ) AS emprise_chute_m2
    FROM uti.couche_livrable_t2h_sol f2
    JOIN uti.t2h_elec_lignes l
      ON l.id_ligne = f2.id_ligne
    WHERE f2.reseau = 'TRANSPORT'
      AND f2.hauteur_ligne_m IS NOT NULL
      AND f2.hauteur_ligne_m > 0
      AND l.geom_sol IS NOT NULL
      AND NOT ST_IsEmpty(l.geom_sol)
    GROUP BY f2.id_ligne, l.geom_sol
) x
WHERE x.id_ligne = f.id_ligne
  AND f.reseau = 'TRANSPORT';


-- ============================================================================
-- 3 — CONTRÔLE STRICT : EXACTEMENT PAIR + IMPAIR PAR LIGNE
-- ============================================================================

CREATE VIEW uti.v_t2h_elec_sol_controle AS
SELECT
    COUNT(*) AS nb_entites,
    COUNT(DISTINCT id_ligne) AS nb_lignes,
    COUNT(*) FILTER (WHERE emplacement = 'PAIR') AS nb_pair,
    COUNT(*) FILTER (WHERE emplacement = 'IMPAIR') AS nb_impair,
    COUNT(*) - 2 * COUNT(DISTINCT id_ligne) AS ecart_attendu,
    COUNT(*) FILTER (
        WHERE emprise_chute_m2 IS NOT NULL
    ) AS nb_avec_emprise_chute,
    ROUND(SUM(surface_m2)::numeric, 2) AS surface_cumulee_m2
FROM uti.couche_livrable_t2h_sol;


DO $controle_pair_impair$
DECLARE
    n_anomalies integer;
    r record;
BEGIN
    SELECT COUNT(*)
    INTO n_anomalies
    FROM (
        SELECT id_ligne
        FROM uti.couche_livrable_t2h_sol
        GROUP BY id_ligne
        HAVING COUNT(*) <> 2
            OR COUNT(DISTINCT emplacement) <> 2
            OR COUNT(*) FILTER (WHERE emplacement = 'PAIR') <> 1
            OR COUNT(*) FILTER (WHERE emplacement = 'IMPAIR') <> 1
    ) q;

    IF n_anomalies > 0 THEN
        RAISE EXCEPTION
            '% ligne(s) ne possèdent pas exactement un côté PAIR et un côté IMPAIR.',
            n_anomalies;
    END IF;

    SELECT * INTO r
    FROM uti.v_t2h_elec_sol_controle;

    RAISE NOTICE '--------------------------------------------------';
    RAISE NOTICE 'COUCHE STRICTE PAIR / IMPAIR';
    RAISE NOTICE '  entités : %', r.nb_entites;
    RAISE NOTICE '  lignes  : %', r.nb_lignes;
    RAISE NOTICE '  PAIR    : %', r.nb_pair;
    RAISE NOTICE '  IMPAIR  : %', r.nb_impair;
    RAISE NOTICE '--------------------------------------------------';
END
$controle_pair_impair$;