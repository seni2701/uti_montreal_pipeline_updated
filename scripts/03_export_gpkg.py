"""
03_export_gpkg.py   (mise à jour post-corrections — 14c / 14c_bis / 14d)
Export DETAIL/REFERENCE du Livrable A vers UTI_Routieres_detail.gpkg :
une couche par table du schéma uti (socle + enrichissement) ainsi que les
références sources, pour inspection/QGIS.

Le livrable final (couche consolidée unique) est desormais produit par
couche_combinee_uti_dedoublonnee.py -> data/processed/UTI_Routieres.gpkg
(cle config sorties.uti_routieres_gpkg). Ce script-ci ecrit sous
sorties.uti_routieres_detail_gpkg pour ne pas ecraser ce livrable.

Nouveautés de cette version (par rapport au post-enrichissement 10–13b) :
  - UTI_rues_polygones lit desormais uti.rues_polygones_enrichies (point A :
    rues redessinees AVEC lots riverains integres — la "carte qui remplace le
    cadastre"). La couche cadastre brute reste disponible en reference.
  - UTI_arbres : colonne hors_emprise exposee ; les points marques hors_emprise
    par 14d sont EXCLUS de la couche livree (ils restent traces en base via
    hors_emprise = true et geom_source).
  - Rappel : parterres et troncons_demis sont maintenant en SRID 2950 (14c/14c_bis) ;
    aucune adaptation d'export necessaire, mais l'export reflete desormais un
    referentiel propre.

Heritage conserve :
  - Interferences scindees par famille geometrique (GPKG n'aime pas le mixte).
  - Colonnes du script 13 sur les couches socle.
  - jsonb -> text.
  - Correction du drapeau `first`.
  - geom_col parametrable ("geom" pour uti.*, "geometry" pour raw.*).

Usage :
    python scripts/03_export_gpkg.py

Sortie : data/processed/UTI_Routieres_detail.gpkg
"""
import sys
import yaml
import geopandas as gpd
from pathlib import Path
from sqlalchemy import text

ROOT = Path(__file__).resolve().parent
for candidate in [ROOT, ROOT / "scripts", ROOT.parent / "scripts"]:
    if (candidate / "utils" / "db.py").exists():
        sys.path.insert(0, str(candidate))
        break
from utils.db import get_engine

CONFIG      = yaml.safe_load((ROOT / "config.yaml").read_text(encoding="utf-8")
              if (ROOT / "config.yaml").exists()
              else (ROOT.parent / "config.yaml").read_text(encoding="utf-8"))
OUTPUT_PATH = Path(CONFIG["sorties"].get(
    "uti_routieres_detail_gpkg", "data/processed/UTI_Routieres_detail.gpkg"))
if not OUTPUT_PATH.is_absolute():
    project_root = ROOT if (ROOT / "config.yaml").exists() else ROOT.parent
    OUTPUT_PATH  = project_root / OUTPUT_PATH
OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)

# Couches à exporter : (nom_layer, requête SQL, colonne géométrie)
LAYERS = [
    # ══════════════════════════════════════════════════════════════════
    # LIVRABLE A — SOCLE (étapes 1 à 6, colonnes du 13 incluses)
    # ══════════════════════════════════════════════════════════════════
    (
        # Point A : la carte qui redessine les rues EN INTEGRANT les lots
        # riverains (rues_polygones_enrichies), et non le cadastre brut.
        "UTI_rues_polygones",
        """SELECT nom_rue, id_utg, nom_utg,
                  nb_lots_integres,
                  ROUND(ST_Area(geom)::numeric, 2) AS surface_m2,
                  geom
           FROM uti.rues_polygones_enrichies ORDER BY nom_rue""",
        "geom",
    ),
    (
        "UTI_troncons",
        """SELECT id_trc, nom_rue, arr_gch, arr_drt,
                  deb_gch, fin_gch, deb_drt, fin_drt,
                  classe, sens_cir,
                  statut_voie, type_voie, usage_voie,
                  surface_m2, longueur_axe_m, largeur_moy_m,
                  flag_surface_aberrante,                       -- script 13
                  geom
           FROM uti.troncons_polygones ORDER BY id_trc""",
        "geom",
    ),
    (
        # Couche de lecture (creer_troncons_entiers.py) : UN enregistrement
        # par RUE NOMMEE et spatialement connexe (blocs/id_trc fusionnes via
        # ST_Collect + ST_LineMerge au sein de chaque cluster spatial), utile
        # pour denombrer/nommer le reseau sans la fragmentation du traitement
        # polygonal (UTI_troncons, ci-dessus).
        # coupee_par_intersections=true est attendu (limite GEOS) : la
        # geometrie reste un MultiLineString a chaque vraie intersection.
        # groupe_homonyme/nb_groupes_homonymes non-NULL signale un nom_rue
        # partage par plusieurs rues distinctes non connectees (ex. avenues
        # numerotees repetees par quartier).
        "UTI_troncons_entiers",
        """SELECT id_rue_entiere, nom_rue, groupe_homonyme,
                  nb_groupes_homonymes, arrondissement, type_voie,
                  longueur_m, nb_troncons, nb_segments_source,
                  coupee_par_intersections, geom
           FROM uti.troncons_entiers ORDER BY id_rue_entiere""",
        "geom",
    ),
    (
        "UTI_parterres",
        """SELECT p.id_trc, p.demi_id, p.cote,
                  p.id_treevans, p.arr_appartenance, p.utg_id,
                  p.statut_voie, p.type_voie, p.usage_voie,
                  p.surface_m2, p.perimetre_m, p.terre_plein,
                  p.rang_surface, p.nb_arbres,                  -- script 13
                  p.presence_trottoir, p.presence_saillie,      -- script 13
                  p.presence_piste_cyclable,                    -- script 13
                  p.flag_multi_parterre,                        -- script 13
                  p.statut_public_prive,                        -- script 13 (dépend 05c)
                  p.geom
           FROM uti.parterres p ORDER BY p.id_trc, p.cote""",
        "geom",
    ),
    (
        "UTI_adresses_troncon",
        """SELECT ta.id_trc, ta.nom_rue,
                  ta.deb_gch, ta.fin_gch, ta.deb_drt, ta.fin_drt,
                  ta.nb_adresses,
                  ta.taux_geocodage, ta.code_postal,            -- script 13
                  tp.geom
           FROM uti.troncons_adresses ta
           JOIN uti.troncons_polygones tp USING (id_trc)
           ORDER BY ta.id_trc""",
        "geom",
    ),
    (
        "UTI_terre_pleins",
        """SELECT id_voirie, type_ilot, categorie,
                  usage_cyclable, presence_arbre,
                  surface_m2, id_trc, nom_rue, geom
           FROM uti.terre_pleins ORDER BY id_trc""",
        "geom",
    ),
    (
        "UTI_rues_limites_utg",
        """SELECT id_trc, nom_rue, arr_gch, arr_drt, geom
           FROM uti.v_rues_limites_utg ORDER BY nom_rue""",
        "geom",
    ),
    (
        "UTI_troncons_lots",
        """SELECT id_treevans, id_trc, cote, arr_appartenance,
                  no_lot, type_lot, arrondissement_lot,
                  surface_lot_m2, type_relation, actif,
                  profil_acces,                                 -- script 13
                  date_creation, date_activation,
                  geom_lot AS geom
           FROM uti.troncons_lots ORDER BY id_treevans""",
        "geom",
    ),

    # ══════════════════════════════════════════════════════════════════
    # LIVRABLE A — ENRICHISSEMENT (scripts 10 à 12 + correctifs)
    # ══════════════════════════════════════════════════════════════════
    (
        "UTI_composantes_voirie",                               # script 10
        """SELECT id_composante, type_composante, categorie,
                  type_trottoir, type_bordure, usage_cyclable,
                  saillie, presence_arbre, materiau,
                  id_trc, id_treevans, surface_m2, geom
           FROM uti.composantes_voirie ORDER BY id_composante""",
        "geom",
    ),
    (
        "UTI_pistes_cyclables",                                 # script 10
        """SELECT id_cyclable, type_amenagement, separateur,
                  protege_4s, route_verte, longueur_m,
                  id_trc, methode_rattachement, geom
           FROM uti.pistes_cyclables ORDER BY id_cyclable""",
        "geom",
    ),
    (
        # scripts 11 + 11b + 14d : on expose hors_emprise et on EXCLUT les
        # points aberrants marques par 14d (ils restent traces en base).
        "UTI_arbres",
        """SELECT id_arbre, emp_no, inv_type, essence, dhp_cm,
                  remarquable, emplacement_src, cote_src,
                  no_civique, rue, type_emplacement,
                  id_trc, id_treevans, id_tp,
                  methode_rattachement, distance_m,
                  hors_emprise,                                 -- script 14d
                  geom
           FROM uti.arbres
           WHERE COALESCE(hors_emprise, false) = false
           ORDER BY id_arbre""",
        "geom",
    ),
    # Interférences (script 12) — table à géométries MIXTES (points +
    # lignes/polygones de chantier) : GPKG refuse le mixte dans une même
    # couche, on scinde donc par famille. jsonb -> text obligatoire.
    (
        "UTI_interferences_ponctuelles",                        # collisions + signalisation
        """SELECT id_interf, categorie, sous_type, id_trc, cote,
                  distance_m, details::text AS details, geom
           FROM uti.interferences_troncon
           WHERE categorie IN ('collision', 'signalisation')
           ORDER BY id_interf""",
        "geom",
    ),
    (
        "UTI_interferences_chantiers",                          # entraves (lignes/polygones)
        """SELECT id_interf, categorie, sous_type, id_trc, cote,
                  distance_m, details::text AS details, geom
           FROM uti.interferences_troncon
           WHERE categorie = 'chantier'
           ORDER BY id_interf""",
        "geom",
    ),

    # ══════════════════════════════════════════════════════════════════
    # RÉFÉRENCES SOURCES (schéma raw ; colonne géométrique = "geometry")
    # NB : collisions, signalisation et chantiers ne sont PAS re-exportés
    # en référence — ils sont déjà intégrés dans les couches d'interférences.
    # ══════════════════════════════════════════════════════════════════
    ("ref_reseau_cyclable",    "SELECT * FROM raw.reseau_cyclable",    "geometry"),
    ("ref_limites_admin",      "SELECT * FROM raw.limites_admin",      "geometry"),
    ("ref_arbres_publics",     "SELECT * FROM raw.arbres_publics",     "geometry"),
    ("ref_batiments",          "SELECT * FROM raw.batiments",          "geometry"),
    ("ref_poles",              "SELECT * FROM raw.poles",              "geometry"),
    ("ref_voirie_active",      "SELECT * FROM raw.voirie_active",      "geometry"),
    ("ref_cadastre",           "SELECT * FROM raw.cadastre",           "geometry"),
    ("ref_conditions_ruelles", "SELECT * FROM raw.conditions_ruelles", "geometry"),
    ("ref_ruelles_vertes",     "SELECT * FROM raw.ruelles_vertes",     "geometry"),
    ("ref_zonage",             "SELECT * FROM raw.zonage",             "geometry"),
]


def export_layer(name: str, sql: str, geom_col: str,
                 engine, output_path: Path, first: bool) -> bool:
    """Exporte une couche ; retourne True si elle a bien été écrite."""
    print(f"  → Exportation de {name}...", end=" ")
    try:
        gdf = gpd.read_postgis(sql, engine, geom_col=geom_col)
        if gdf.empty:
            print("[ignoré — table vide]")
            return False
        # Renommer la colonne géométrique en "geom" pour homogénéité GPKG
        if geom_col != "geom":
            gdf = gdf.rename_geometry("geom")
        mode = "w" if first else "a"
        gdf.to_file(str(output_path), layer=name, driver="GPKG", mode=mode)
        print(f"[ok] {len(gdf):,} entités")
        return True
    except Exception as e:
        print(f"[ignoré] {e}")
        return False


def main():
    engine = get_engine()
    print(f"\n[UTI_Routieres.gpkg] Export Livrable A — socle + enrichissement (post-14c/14d)")
    print(f"  Destination : {OUTPUT_PATH}\n")

    # Repartir d'un fichier propre : évite les couches orphelines d'un
    # export précédent (le mode "w" GPKG ne purge que la couche visée).
    if OUTPUT_PATH.exists():
        OUTPUT_PATH.unlink()
        print("  (ancien GeoPackage supprimé — export à neuf)\n")

    exported = 0
    first = True
    for name, sql, geom_col in LAYERS:
        ok = export_layer(name, sql, geom_col, engine, OUTPUT_PATH, first)
        if ok:
            exported += 1
            first = False   # ne bascule qu'après une PREMIÈRE écriture réussie

    size_mb = OUTPUT_PATH.stat().st_size / 1e6 if OUTPUT_PATH.exists() else 0
    print(f"\n[ok] Fichier généré : {OUTPUT_PATH.name} ({size_mb:.1f} Mo)")
    print(f"     Couches exportées : {exported} / {len(LAYERS)}")
    print(f"\n     Ouvrir dans QGIS :")
    print(f"     Couche → Ajouter une couche → Vecteur → {OUTPUT_PATH}")


if __name__ == "__main__":
    main()