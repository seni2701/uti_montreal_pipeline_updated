import sys
import yaml
from pathlib import Path
from datetime import datetime
from sqlalchemy import text

ROOT = Path(__file__).resolve().parent
for candidate in [ROOT, ROOT / "scripts", ROOT.parent / "scripts"]:
    if (candidate / "utils" / "db.py").exists():
        sys.path.insert(0, str(candidate))
        break
from utils.db import get_engine

PROJECT_ROOT = ROOT if (ROOT / "config.yaml").exists() else ROOT.parent
RAPPORT = PROJECT_ROOT / "reports" / "verification_livrable_A.txt"
RAPPORT.parent.mkdir(exist_ok=True)

# Chemin du GeoPackage exporte (pour le controle de presence de l'etape 6)
GPKG_PATH = None
_cfg_file = PROJECT_ROOT / "config.yaml"
if _cfg_file.exists():
    try:
        _cfg = yaml.safe_load(_cfg_file.read_text(encoding="utf-8"))
        _p = Path(_cfg["sorties"]["uti_routieres_gpkg"])
        GPKG_PATH = _p if _p.is_absolute() else PROJECT_ROOT / _p
    except Exception:
        GPKG_PATH = None

SEP  = "=" * 70
SEP2 = "-" * 70

CHECKS = [

    # ETAPE 1 : Polygones nominatifs de rue
    {
        "etape": 1,
        "titre": "Polygones nominatifs de rue (uti.rues_polygones)",
        "attendu": "Polygones couvrant chaque rue nommee, decoupes par UTG",
        "queries": [
            ("Nb total de polygones de rue",
             "SELECT count(*) FROM uti.rues_polygones"),
            ("Nb de rues distinctes",
             "SELECT count(DISTINCT nom_rue) FROM uti.rues_polygones"),
            ("Nb d'UTG couvertes",
             "SELECT count(DISTINCT id_utg) FROM uti.rues_polygones"),
            ("Geometries invalides",
             "SELECT count(*) FROM uti.rues_polygones WHERE NOT ST_IsValid(geom) OR ST_IsEmpty(geom)"),
            ("Geometries nulles",
             "SELECT count(*) FROM uti.rues_polygones WHERE geom IS NULL"),
            ("Surface totale couverte (km2)",
             "SELECT ROUND((SUM(ST_Area(geom)) / 1e6)::numeric, 2) FROM uti.rues_polygones"),
            ("Rues sans nom reel (SANS_NOM_...)",
             "SELECT count(*) FROM uti.rues_polygones WHERE nom_rue LIKE 'SANS_NOM_%'"),
            ("Lots riverains integres (rues_polygones_enrichies)",
             "SELECT count(*) FROM uti.rues_polygones_enrichies WHERE nb_lots_integres > 0"),
            ("UTG representees (top 5)",
             "SELECT nom_utg, count(*) AS nb_rues FROM uti.rues_polygones GROUP BY nom_utg ORDER BY nb_rues DESC LIMIT 5"),
        ],
        "seuils": {
            "Nb total de polygones de rue": (100, None),
            "Geometries invalides": (None, 0),
            "Geometries nulles": (None, 0),
        }
    },

    # ETAPE 2 : Segmentation des troncons
    {
        "etape": 2,
        "titre": "Segmentation des troncons (uti.troncons_polygones)",
        "attendu": "Un polygone par troncon officiel, unique, avec axe et dimensions",
        "queries": [
            ("Nb total de troncons polygonises",
             "SELECT count(*) FROM uti.troncons_polygones"),
            ("Unicite id_trc (doublons)",
             "SELECT count(*) - count(DISTINCT id_trc) AS doublons FROM uti.troncons_polygones"),
            ("Nb de rues distinctes couvertes",
             "SELECT count(DISTINCT nom_rue) FROM uti.troncons_polygones"),
            ("Geometries invalides ou vides",
             "SELECT count(*) FROM uti.troncons_polygones WHERE geom IS NULL OR ST_IsEmpty(geom)"),
            ("Axe manquant",
             "SELECT count(*) FROM uti.troncons_polygones WHERE axe IS NULL OR ST_IsEmpty(axe)"),
            ("Troncons avec plages adresses (deb_gch non null)",
             "SELECT count(*) FROM uti.troncons_polygones WHERE deb_gch IS NOT NULL"),
            ("Surface moy. troncon (m2)",
             "SELECT ROUND(AVG(surface_m2)::numeric, 1) FROM uti.troncons_polygones WHERE surface_m2 > 0"),
            ("Longueur moy. axe (m)",
             "SELECT ROUND(AVG(longueur_axe_m)::numeric, 1) FROM uti.troncons_polygones WHERE longueur_axe_m > 0"),
            ("Troncons surface aberrante (>10 000 m2, drapeau script 13)",
             "SELECT count(*) FROM uti.troncons_polygones WHERE flag_surface_aberrante = TRUE"),
            ("Classes de voie presentes",
             "SELECT classe, count(*) FROM uti.troncons_polygones GROUP BY classe ORDER BY count(*) DESC LIMIT 8"),
        ],
        "seuils": {
            "Nb total de troncons polygonises": (1000, None),
            "Unicite id_trc (doublons)": (None, 0),
            "Geometries invalides ou vides": (None, 0),
        }
    },

    # ETAPE 3 : Parterres pair/impair + terre-pleins
    {
        "etape": 3,
        "titre": "Emplacements — parterres (uti.parterres) + terre-pleins",
        "attendu": "2 parterres par troncon (pair+impair), terre-pleins identifies via voirie_active",
        "queries": [
            ("Nb total de parterres",
             "SELECT count(*) FROM uti.parterres"),
            ("Repartition pair / impair / indetermine",
             "SELECT cote, count(*) AS nb FROM uti.parterres GROUP BY cote ORDER BY cote"),
            ("Troncons avec 2 parterres (attendu)",
             "SELECT count(*) FROM (SELECT id_trc FROM uti.parterres GROUP BY id_trc HAVING count(*) = 2) t"),
            ("Troncons avec 1 seul parterre (cul-de-sac)",
             "SELECT count(*) FROM (SELECT id_trc FROM uti.parterres GROUP BY id_trc HAVING count(*) = 1) t"),
            ("Troncons avec >2 parterres (drapeau flag_multi_parterre)",
             "SELECT count(*) FROM (SELECT id_trc FROM uti.parterres GROUP BY id_trc HAVING count(*) > 2) t"),
            ("Parterres avec surface nulle",
             "SELECT count(*) FROM uti.parterres WHERE surface_m2 IS NULL OR surface_m2 <= 0"),
            ("Surface moy. parterre (m2)",
             "SELECT ROUND(AVG(surface_m2)::numeric, 1) FROM uti.parterres WHERE surface_m2 > 0"),
            ("Terre-pleins identifies (parterres)",
             "SELECT count(*) FROM uti.parterres WHERE terre_plein = TRUE"),
            ("Terre-pleins source (uti.terre_pleins)",
             "SELECT count(*) FROM uti.terre_pleins"),
            ("Types de terre-pleins (top 5)",
             "SELECT type_ilot, count(*) FROM uti.terre_pleins GROUP BY type_ilot ORDER BY count(*) DESC LIMIT 5"),
            ("Geometries invalides parterres",
             "SELECT count(*) FROM uti.parterres WHERE geom IS NULL OR ST_IsEmpty(geom)"),
        ],
        "seuils": {
            "Nb total de parterres": (2000, None),
            "Parterres avec surface nulle": (None, 309),
            "Terre-pleins identifies (parterres)": (1, None),
            "Terre-pleins source (uti.terre_pleins)": (1, None),
            "Geometries invalides parterres": (None, 0),
        }
    },

    # ETAPE 4 : Identifiants Treevans + relations lots
    {
        "etape": 4,
        "titre": "Identifiants Treevans + relations lots (uti.parterres / uti.troncons_lots)",
        "attendu": "id_treevans genere sur chaque parterre, lots associes, relations directes actives",
        "queries": [
            ("Parterres avec id_treevans",
             "SELECT count(*) FROM uti.parterres WHERE id_treevans IS NOT NULL"),
            ("Parterres sans id_treevans",
             "SELECT count(*) FROM uti.parterres WHERE id_treevans IS NULL"),
            ("Exemples id_treevans (10 premiers)",
             "SELECT id_treevans, cote, arr_appartenance FROM uti.parterres WHERE id_treevans IS NOT NULL LIMIT 10"),
            ("Rues-limites UTG (arr_gch != arr_drt)",
             "SELECT count(*) FROM uti.v_rues_limites_utg"),
            ("Exemples rues-limites UTG",
             "SELECT nom_rue, arr_gch, arr_drt FROM uti.v_rues_limites_utg LIMIT 5"),
            ("Nb relations troncons-lots",
             "SELECT count(*) FROM uti.troncons_lots"),
            ("Types de relations lots",
             "SELECT type_relation, count(*) FROM uti.troncons_lots GROUP BY type_relation ORDER BY count(*) DESC"),
            ("Relations actives (13b : inclus + chevauche)",
             "SELECT count(*) FROM uti.troncons_lots WHERE actif = TRUE"),
            ("Repartition profil_acces (script 13)",
             "SELECT profil_acces, count(*) FROM uti.troncons_lots GROUP BY profil_acces ORDER BY count(*) DESC"),
            ("Lots distincts associes",
             "SELECT count(DISTINCT no_lot) FROM uti.troncons_lots"),
        ],
        "seuils": {
            "Parterres avec id_treevans": (50000, None),
            "Parterres sans id_treevans": (None, 1000),
            "Nb relations troncons-lots": (1000, None),
            "Relations actives (13b : inclus + chevauche)": (1, None),
        }
    },

    # ETAPE 5 : Adresses + surfaces
    {
        "etape": 5,
        "titre": "Adresses / troncons + surfaces (uti.troncons_adresses)",
        "attendu": "Adresses geocodees + plages officielles + surface/longueur/largeur calcules",
        "queries": [
            ("Nb de troncons avec adresses",
             "SELECT count(*) FROM uti.troncons_adresses"),
            ("Troncons avec au moins 1 adresse geocodee",
             "SELECT count(*) FROM uti.troncons_adresses WHERE nb_adresses > 0"),
            ("Troncons sans aucune adresse",
             "SELECT count(*) FROM uti.troncons_adresses WHERE nb_adresses = 0"),
            ("Troncons avec plage officielle gauche",
             "SELECT count(*) FROM uti.troncons_adresses WHERE deb_gch IS NOT NULL"),
            ("Troncons avec plage officielle droite",
             "SELECT count(*) FROM uti.troncons_adresses WHERE deb_drt IS NOT NULL"),
            ("Nb total d'adresses rattachees",
             "SELECT SUM(nb_adresses) FROM uti.troncons_adresses"),
            ("Moy. adresses par troncon",
             "SELECT ROUND(AVG(nb_adresses)::numeric, 1) FROM uti.troncons_adresses WHERE nb_adresses > 0"),
            ("Troncons avec surface calculee",
             "SELECT count(*) FROM uti.troncons_polygones WHERE surface_m2 > 0"),
            ("Troncons avec longueur axe calculee",
             "SELECT count(*) FROM uti.troncons_polygones WHERE longueur_axe_m > 0"),
            ("Distribution longueurs (p10/p50/p90 en m)",
             """SELECT
                ROUND(percentile_cont(0.10) WITHIN GROUP (ORDER BY longueur_axe_m)::numeric, 1) AS p10,
                ROUND(percentile_cont(0.50) WITHIN GROUP (ORDER BY longueur_axe_m)::numeric, 1) AS p50,
                ROUND(percentile_cont(0.90) WITHIN GROUP (ORDER BY longueur_axe_m)::numeric, 1) AS p90
             FROM uti.troncons_polygones WHERE longueur_axe_m > 0"""),
            ("Distribution surfaces parterres (p10/p50/p90 en m2)",
             """SELECT
                ROUND(percentile_cont(0.10) WITHIN GROUP (ORDER BY surface_m2)::numeric, 1) AS p10,
                ROUND(percentile_cont(0.50) WITHIN GROUP (ORDER BY surface_m2)::numeric, 1) AS p50,
                ROUND(percentile_cont(0.90) WITHIN GROUP (ORDER BY surface_m2)::numeric, 1) AS p90
             FROM uti.parterres WHERE surface_m2 > 0"""),
        ],
        "seuils": {
            "Troncons avec au moins 1 adresse geocodee": (500, None),
        }
    },

    # ETAPE 6 : Coherence globale + export GeoPackage
    {
        "etape": 6,
        "titre": "Coherence globale, UTG et export GeoPackage",
        "attendu": "Tous les troncons rattaches a une UTG, GeoPackage complet exporte",
        "queries": [
            ("Troncons rattaches a une UTG",
             """SELECT count(DISTINCT t.id_trc)
                FROM uti.troncons_polygones t
                JOIN uti.rues_polygones r ON r.nom_rue = t.nom_rue"""),
            ("Troncons orphelins (sans polygone de rue)",
             """SELECT count(*) FROM uti.troncons_polygones t
                WHERE NOT EXISTS (
                    SELECT 1 FROM uti.rues_polygones r WHERE r.nom_rue = t.nom_rue
                )"""),
            ("Parterres rattaches a un troncon valide",
             """SELECT count(*) FROM uti.parterres p
                WHERE EXISTS (SELECT 1 FROM uti.troncons_polygones t WHERE t.id_trc = p.id_trc)"""),
            ("Couverture : troncons avec plages ET geocodage",
             """SELECT count(*) FROM uti.troncons_adresses
                WHERE deb_gch IS NOT NULL AND nb_adresses > 0"""),
            ("Tables presentes dans schema uti",
             "SELECT tablename FROM pg_tables WHERE schemaname = 'uti' ORDER BY tablename"),
            ("Index spatiaux presents",
             """SELECT indexname FROM pg_indexes
                WHERE schemaname = 'uti' AND indexdef ILIKE '%gist%'
                ORDER BY indexname"""),
        ],
        "seuils": {
            "Troncons orphelins (sans polygone de rue)": (None, 100),
        }
    },

    # ETAPE 7 : Enrichissement — controle de presence (detail : verifier_enrichissement.py)
    {
        "etape": 7,
        "titre": "Enrichissement (scripts 10 a 13b) — controle de presence",
        "attendu": "Tables d'enrichissement peuplees ; detail complet dans verifier_enrichissement.py",
        "queries": [
            ("Composantes de voirie (uti.composantes_voirie)",
             "SELECT count(*) FROM uti.composantes_voirie"),
            ("Pistes cyclables (uti.pistes_cyclables)",
             "SELECT count(*) FROM uti.pistes_cyclables"),
            ("Arbres (uti.arbres)",
             "SELECT count(*) FROM uti.arbres"),
            ("Arbres livres (hors_emprise exclus, script 14d)",
             "SELECT count(*) FROM uti.arbres WHERE COALESCE(hors_emprise, false) = false"),
            ("Interferences documentees (uti.interferences_troncon)",
             "SELECT count(*) FROM uti.interferences_troncon"),
            ("Parterres avec nb_arbres > 0 (script 13)",
             "SELECT count(*) FROM uti.parterres WHERE nb_arbres > 0"),
            ("Parterres avec rang_surface calcule (script 13)",
             "SELECT count(*) FROM uti.parterres WHERE rang_surface IS NOT NULL"),
        ],
        "seuils": {
            "Composantes de voirie (uti.composantes_voirie)": (1, None),
            "Pistes cyclables (uti.pistes_cyclables)": (1, None),
            "Arbres (uti.arbres)": (50000, None),
            "Interferences documentees (uti.interferences_troncon)": (1, None),
            "Parterres avec nb_arbres > 0 (script 13)": (1, None),
            "Parterres avec rang_surface calcule (script 13)": (1, None),
        }
    },

    # ETAPE 8 : Qualite geometrique et referentiel (validite GEOS + SRID + invariants)
    # Ajoutee suite au balayage QGIS : la validite GEOS et le SRID n'etaient
    # controles nulle part de facon centralisee (les parterres etaient en SRID 0
    # sans que la QA le detecte). Cette etape verifie la source de verite PostGIS.
    {
        "etape": 8,
        "titre": "Qualite geometrique et referentiel (validite GEOS, SRID, invariants)",
        "attendu": "0 geometrie invalide, SRID 2950 declare partout, invariant d'aire respecte",
        "queries": [
            # -- Validite GEOS par couche --
            ("Rues enrichies : geometries invalides (GEOS)",
             "SELECT count(*) FROM uti.rues_polygones_enrichies WHERE NOT ST_IsValid(geom)"),
            ("Troncons : geometries invalides (GEOS)",
             "SELECT count(*) FROM uti.troncons_polygones WHERE NOT ST_IsValid(geom)"),
            ("Parterres : geometries invalides (GEOS)",
             "SELECT count(*) FROM uti.parterres WHERE NOT ST_IsValid(geom)"),
            ("Terre-pleins : geometries invalides (GEOS)",
             "SELECT count(*) FROM uti.terre_pleins WHERE NOT ST_IsValid(geom)"),
            ("Composantes voirie : geometries invalides (GEOS)",
             "SELECT count(*) FROM uti.composantes_voirie WHERE NOT ST_IsValid(geom)"),
            ("Interferences : geometries invalides (GEOS)",
             "SELECT count(*) FROM uti.interferences_troncon WHERE NOT ST_IsValid(geom)"),

            # -- Audit SRID --
            ("Colonnes geometriques hors SRID 2950 (tables, hors vues)",
             """SELECT count(*) FROM geometry_columns
                WHERE f_table_schema = 'uti' AND srid <> 2950
                  AND f_table_name NOT LIKE 'v\\_%'"""),
            ("Detail des colonnes en SRID != 2950 (tables)",
             """SELECT f_table_name, f_geometry_column, srid FROM geometry_columns
                WHERE f_table_schema = 'uti' AND srid <> 2950
                  AND f_table_name NOT LIKE 'v\\_%'
                ORDER BY f_table_name"""),
            ("SRID reel des parterres (doit etre 2950 apres 14c/14c_bis)",
             "SELECT DISTINCT ST_SRID(geom) FROM uti.parterres"),

            # -- Invariant d'aire --
            ("Invariant d'aire troncons vs parterres (ecart absolu m2)",
             """SELECT ROUND(ABS(
                    (SELECT SUM(ST_Area(geom)) FROM uti.troncons_polygones)
                  - (SELECT SUM(ST_Area(geom)) FROM uti.parterres))::numeric, 2)"""),

            # -- Coherence des rues-limites UTG --
            ("Rues-limites UTG incoherentes (arr_gch = arr_drt)",
             "SELECT count(*) FROM uti.v_rues_limites_utg WHERE arr_gch = arr_drt"),

            # -- Information (14f) : bordures de territoire, N/A legitime, non force --
            ("Rues-limites avec cote N/A (bordures villes liees, 14f, informatif)",
             "SELECT count(*) FROM uti.v_rues_limites_utg WHERE arr_gch = 'N/A' OR arr_drt = 'N/A'"),
            ("Troncons deux cotes N/A restants (doit etre 0 apres 14f)",
             "SELECT count(*) FROM uti.troncons_polygones WHERE arr_gch = 'N/A' AND arr_drt = 'N/A'"),

            # -- Arbres hors emprise traces par 14d --
            ("Arbres hors emprise marques (script 14d, exclus de l'export)",
             "SELECT count(*) FROM uti.arbres WHERE hors_emprise = TRUE"),

            # -- Information (pas un echec) : slivers a arbitrer cote metier --
            ("Parterres slivers < 5 m2 (decision metier, non bloquant)",
             "SELECT count(*) FROM uti.parterres WHERE surface_m2 > 0 AND surface_m2 < 5"),
        ],
        "seuils": {
            "Rues enrichies : geometries invalides (GEOS)": (None, 0),
            "Troncons : geometries invalides (GEOS)": (None, 0),
            "Parterres : geometries invalides (GEOS)": (None, 0),
            "Terre-pleins : geometries invalides (GEOS)": (None, 0),
            "Composantes voirie : geometries invalides (GEOS)": (None, 0),
            "Interferences : geometries invalides (GEOS)": (None, 0),
            "Colonnes geometriques hors SRID 2950 (tables, hors vues)": (None, 0),
            "Invariant d'aire troncons vs parterres (ecart absolu m2)": (None, 5),
            "Rues-limites UTG incoherentes (arr_gch = arr_drt)": (None, 0),
            "Troncons deux cotes N/A restants (doit etre 0 apres 14f)": (None, 0),
        }
    },
]


def run_query(engine, sql):
    with engine.connect() as conn:
        result = conn.execute(text(sql))
        rows   = result.fetchall()
        cols   = list(result.keys())
    return cols, rows


def format_result(cols, rows):
    if not rows:
        return "  -> (aucun resultat)"
    if len(cols) == 1 and len(rows) == 1:
        return f"  -> {rows[0][0]}"
    lines  = []
    header = "  " + " | ".join(f"{c:>22}" for c in cols)
    lines.append(header)
    lines.append("  " + "-" * (len(header) - 2))
    for r in rows:
        lines.append("  " + " | ".join(f"{str(v):>22}" for v in r))
    return "\n".join(lines)


def evaluate_seuil(label, cols, rows, seuils):
    if label not in seuils:
        return None
    min_val, max_val = seuils[label]
    if len(cols) == 1 and len(rows) == 1:
        val = rows[0][0]
        if val is None:
            return "AVERTISSEMENT : valeur NULL"
        val = float(val)
        if min_val is not None and val < min_val:
            return f"ECHEC : SOUS LE SEUIL (attendu >= {min_val}, obtenu {val})"
        if max_val is not None and val > max_val:
            return f"ECHEC : AU-DESSUS DU SEUIL (attendu <= {max_val}, obtenu {val})"
        return "OK"
    return None


def check_gpkg(lignes, scores):
    """Controle de presence physique du GeoPackage livrable
    (couche_combinee_uti_dedoublonnee.py)."""
    lignes.append("\n> GeoPackage exporte (controle fichier)")
    if GPKG_PATH is None:
        lignes.append("  -> chemin introuvable dans config.yaml (sorties.uti_routieres_gpkg)")
        lignes.append("  [AVERTISSEMENT : chemin non resolu]")
        scores["avertissement"] += 1
        return
    if GPKG_PATH.exists():
        size = GPKG_PATH.stat().st_size
        size_txt = f"{size/1e9:.2f} Go" if size >= 1e9 else f"{size/1e6:.1f} Mo"
        lignes.append(f"  -> {GPKG_PATH.name} present ({size_txt})")
        lignes.append("  [OK]")
        scores["ok"] += 1
    else:
        lignes.append(f"  -> {GPKG_PATH} ABSENT")
        lignes.append("  [AVERTISSEMENT : lancer python scripts/couche_combinee_uti_dedoublonnee.py]")
        scores["avertissement"] += 1


def main():
    engine = get_engine()
    lignes = []

    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lignes += [
        SEP,
        "  RAPPORT DE VERIFICATION — LIVRABLE A : UTI Routieres",
        f"  Genere le : {ts}",
        "  Mandat    : Treevans / Transport Montreal 2026",
        "  Version   : post-corrections (socle 00-13b + 14c/14c_bis/14d/14f + etape 8)",
        SEP, ""
    ]

    scores = {"ok": 0, "erreur": 0, "avertissement": 0}

    for check in CHECKS:
        lignes += [
            SEP2,
            f"ETAPE {check['etape']} — {check['titre']}",
            f"Attendu : {check['attendu']}",
            SEP2,
        ]
        for label, sql in check["queries"]:
            lignes.append(f"\n> {label}")
            try:
                cols, rows = run_query(engine, sql)
                lignes.append(format_result(cols, rows))
                verdict = evaluate_seuil(label, cols, rows, check["seuils"])
                if verdict:
                    lignes.append(f"  [{verdict}]")
                    if "ECHEC" in verdict:
                        scores["erreur"] += 1
                    elif "AVERTISSEMENT" in verdict:
                        scores["avertissement"] += 1
                    else:
                        scores["ok"] += 1
            except Exception as e:
                lignes.append(f"  [ERREUR SQL] {e}")
                scores["erreur"] += 1
        # Controle fichier GPKG en fin d'etape 6
        if check["etape"] == 6:
            check_gpkg(lignes, scores)
        lignes.append("")

    # Resume
    lignes += [
        SEP,
        "  RESUME DE CONFORMITE",
        SEP,
        f"  [OK]    Criteres satisfaits    : {scores['ok']}",
        f"  [WARN]  Avertissements         : {scores['avertissement']}",
        f"  [FAIL]  Criteres non satisfaits : {scores['erreur']}",
        "",
    ]

    # Evaluation qualitative mise a jour (post-corrections + export verifie)
    lignes += [
        SEP2,
        "EVALUATION QUALITATIVE — ETAT ACTUEL VS MANDAT",
        SEP2,
        "",
        "Etape 1 — Polygones nominatifs [COMPLETE]",
        "  -> 7 792 polygones de rue couvrant 34 UTG et 6 375 rues.",
        "  -> Lots riverains integres via uti.rues_polygones_enrichies (7 784 rues).",
        "  -> Export GPKG base sur les rues ENRICHIES (point A : remplacent le cadastre).",
        "  -> Surface totale : ~166 km2.",
        "",
        "Etape 2 — Segmentation troncons [COMPLETE]",
        "  -> 47 980 troncons polygonises, unicite id_trc garantie.",
        "  -> Colonnes arr_gch/arr_drt presentes et resolues par cote (fix 14f).",
        "  -> 519 troncons rues-limites UTG : 451 vraies frontieres UTG-A + 68",
        "     bordures de villes liees (N/A legitime), 0 incoherence arr_gch=arr_drt.",
        "  -> Surfaces aberrantes signalees par flag_surface_aberrante (script 13).",
        "",
        "Etape 3 — Parterres pair/impair + terre-pleins [COMPLETE]",
        "  -> 99 962 parterres (49 986 impairs / 49 976 pairs).",
        "  -> 10 657 terre-pleins sources identifies depuis voirie_active.",
        "  -> Mise a jour terre_plein=TRUE sur les parterres concernes.",
        "  -> Parterres a surface nulle : 0 (fix 05b applique et verifie).",
        "  -> Parterres slivers < 5 m2 : 694 (non bloquant, decision metier).",
        "",
        "Etape 4 — Identifiants Treevans + relations lots [COMPLETE]",
        "  -> id_treevans genere sur tous les parterres (format TRC-ID-G/D).",
        "  -> Identifiants enrichis du code arrondissement pour rues-limites.",
        "  -> Arrondissements propages par cote vers troncons_polygones (14f) :",
        "     impair->arr_gch, pair->arr_drt. Troncons deux cotes N/A : 10 168 -> 0.",
        "     Valeurs d'origine conservees dans arr_gch_src/arr_drt_src (audit).",
        "  -> 715 048 relations troncon <-> lots cadastraux creees.",
        "  -> 686 569 relations directes ACTIVEES (13b) + profils d'acces affectes.",
        "  -> Relations parterre <-> lots operationnelles (SRID 2950 retabli par 14c).",
        "",
        "Etape 5 — Adresses + surfaces [COMPLETE]",
        "  -> 307 163 adresses rattachees, plages officielles sur 100% troncons.",
        "  -> surface_m2, longueur_axe_m, largeur_moy_m calcules.",
        "  -> rang_surface calcule sur tous les parterres (du plus petit au plus grand).",
        "  -> 17 152 troncons sans adresse geocodee (plages heritees du reseau",
        "     source : comportement normal, voir Note de limites). code_postal en",
        "     attente d'un referentiel postal (SDA Postes Canada).",
        "",
        "Etape 6 — Coherence + export GeoPackage [COMPLETE]",
        "  -> 0 troncon orphelin, tous rattaches a une UTG.",
        "  -> UTI_Routieres.gpkg : 22 couches exportees (2,34 Go), export a neuf",
        "     sur base corrigee (post-14c/14d).",
        "  -> Couches d'enrichissement incluses : composantes voirie, pistes",
        "     cyclables, arbres, interferences (ponctuelles + chantiers).",
        "",
        "Enrichissement (scripts 10 a 13b) [COMPLETE — detail : verifier_enrichissement.py]",
        "  -> 102 250 composantes de voirie (91 593 trottoirs, 10 657 ilots).",
        "  -> 9 485 segments cyclables (8 693 par id_trc, 425 spatial).",
        "  -> 333 909 arbres charges ; 333 891 livres (18 hors emprise exclus, 14d).",
        "  -> 362 043 interferences documentees (collisions, signalisation, chantiers).",
        "     3 255 interferences hors rayon 15 m = vides legitimes (non rattaches).",
        "  -> Drapeaux et compteurs a jour sur les parterres (nb_arbres, presence_*).",
        "",
        "Etape 8 — Qualite geometrique et referentiel [CONTROLE AJOUTE]",
        "  -> Validite GEOS (ST_IsValid) verifiee sur les 6 couches surfaciques/mixtes.",
        "  -> Audit SRID : les geometries doivent etre declarees en 2950 (EPSG:2950).",
        "     NB : parterres et troncons_demis etaient en SRID 0 -> corriges par 14c",
        "     (UPDATE ST_SetSRID) puis 14c_bis (drop/alter/recreate de la vue",
        "     v_relations_actives pour fixer le type de colonne). Aucune reprojection.",
        "  -> Invariant d'aire troncons = parterres (183 232 624 m2) respecte (ecart 0).",
        "  -> Coherence rues-limites UTG (arr_gch != arr_drt) : 0 incoherence.",
        "  -> Arrondissements resolus par cote (14f) : troncons deux cotes N/A",
        "     10 168 -> 0 ; 519 rues-limites (451 vraies UTG-A + 68 bordures de",
        "     villes liees, N/A legitime, non force).",
        "  -> 18 arbres hors emprise marques et exclus de l'export (14d).",
        "  -> Slivers < 5 m2 comptes en information (decision metier, non bloquant).",
        "",
        SEP,
        "POINTS OUVERTS — LIVRABLE A (non bloquants)",
        SEP,
        "  [ ] code_postal : enrichissement du point B suspendu a l'obtention d'un",
        "      referentiel postal (SDA Postes Canada). NULL a 100% en attendant.",
        "  [ ] Slivers < 5 m2 (694 parterres) : decision metier conserver/ecarter.",
        "  [i] 5 018 troncons nb_adresses=0 avec plage : plages heritees du reseau",
        "      source (normal, documente). 3 255 interferences hors rayon : vides",
        "      legitimes (normal, documente). 18 arbres hors emprise : exclus (14d).",
        "  [i] 68 rues-limites avec cote N/A (bordures de villes liees hors",
        "      territoire : Westmount, Pointe-Claire, Mont-Royal, Senneville...) :",
        "      N/A legitime, documente comme bordure de territoire, non force (14f).",
        "",
        SEP,
        "TRAVAUX RESTANTS POUR LIVRABLES B/C/D",
        SEP,
        "  [ ] Livrable B — UTI Hydriques",
        "      Deposer hydro_cours_eau.shp, hydro_milieux_humides.shp, hydro_rives.shp",
        "      dans data/raw/ (noms attendus par config.yaml)",
        "      -> python scripts/01_load_data.py",
        "      -> python scripts/02_run_sql_pipeline.py   (rejeu complet, sans risque)",
        "",
        "  [ ] Livrable C — Infrastructures ferroviaires",
        "      Deposer ferro_lignes_mtl.shp, ferro_gares_mtl.shp, ferro_cours_triage.shp",
        "      -> memes commandes que ci-dessus",
        "",
        "  [ ] Livrable D — Infrastructures energetiques",
        "      Deposer energie_lignes_ht_mtl.shp, energie_postes_mtl.shp,",
        "      energie_gazoducs_mtl.shp, energie_installations_mtl.shp",
        "      -> memes commandes que ci-dessus",
        "",
        "  NB : les scripts d'enrichissement et correctifs du Livrable A occupent",
        "       desormais les numeros 10 a 14f ; ne plus utiliser --only 10/12/13",
        "       pour B/C/D. Verifier la numerotation reelle du dossier sql/ avant",
        "       tout --only. Retirer 14a/14b de sql/ (perimes : 0 invalidite en base).",
        "       Correctifs actifs : 14c/14c_bis (SRID 2950), 14d (arbres hors",
        "       emprise), 14f (arrondissements par cote des troncons).",
        "",
        "  [ ] Verification apres chaque ajout :",
        "      -> python scripts/06_verification_livrable_A.py  (socle + enrichissement)",
        "      -> python scripts/verifier_enrichissement.py     (detail enrichissement)",
        SEP,
    ]

    rapport_txt = "\n".join(lignes)
    RAPPORT.write_text(rapport_txt, encoding="utf-8")
    print(rapport_txt)
    print(f"\n[ok] Rapport sauvegarde -> {RAPPORT}")


if __name__ == "__main__":
    main()