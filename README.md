# Pipeline UTI — Montréal (IAER Solutions / Treevans)

Environnement de travail pour les Livrables A (UTI Routières), B (UTI Hydriques)
et **C (UTI Infrastructures Ferroviaires & Énergétiques)**
du contrat de services indépendants. Convention héritée de CARTHAB : les scripts
numérotés ne sont jamais modifiés une fois validés ; tout correctif part dans un
nouveau fichier (ex. `03b_fix_parite.sql`).

## 1. Démarrer la base PostGIS (Docker — recommandé, le plus rapide)

```bash
docker compose up -d
```

Sans Docker : installer PostgreSQL + PostGIS localement et créer la base
`uti_montreal` manuellement, puis ajuster `.env`.

## 2. Créer l'environnement conda

```bash
conda env create -f environment.yml
conda activate uti-montreal
cp .env.example .env        # ajuster les identifiants si besoin
```

## 3. Déposer les données téléchargées

Renommer/placer les fichiers téléchargés dans `data/raw/` selon les noms
attendus dans `config.yaml`.

### Livrables A & B 

| Clé config              | Fichier attendu                     | Source |
|-------------------------|-------------------------------------|--------|
| `cadastre`              | `cadastre_mtl.shp`                  | Ville de Montréal |
| `reseau_routier`        | `reseau_routier_mtl.shp`            | Ville de Montréal |
| `troncons_officiels`    | `troncon_mtl.shp`                   | Ville de Montréal |
| `adresses`              | `adresses_mtl.shp`                  | Ville de Montréal |
| `utg`                   | `utg_mtl.shp`                       | Ville de Montréal |
| `hydro_cours_eau`       | `hydro_cours_eau.shp`               | PRMHH / Géo-MTL |
| `hydro_milieux_humides` | `hydro_milieux_humides.shp`         | PRMHH / Géo-MTL |
| `hydro_rives`           | `hydro_rives.shp`                   | CARTO DRA |

### Livrable C — Ferroviaire
| Clé config              | Fichier attendu                     | Source recommandée |
|-------------------------|-------------------------------------|--------------------|
| `ferro_lignes`          | `ferro_lignes_mtl.shp`              | Ressources naturelles Canada — Réseau ferroviaire national|
| `ferro_gares`           | `ferro_gares_mtl.shp`               | RNCan / ARTM / données ouvertes exo |
| `ferro_cours_triage`    | `ferro_cours_triage.shp`            | RNCan / OSM (extraction Overpass : `railway=yard`) |

### Livrable D — Énergie 
| Clé config              | Fichier attendu                       | Source recommandée |
|-------------------------|---------------------------------------|--------------------|
| `energie_lignes_ht`     | `energie_lignes_ht_mtl.shp`           | RNCan — Lignes de transport d'électricité|
| `energie_postes`        | `energie_postes_mtl.shp`              | RNCan / Hydro-Québec données ouvertes |
| `energie_gazoducs`      | `energie_gazoducs_mtl.shp`            | RNCan — Pipelines nationaux / Énergir |
| `energie_installations` | `energie_installations_mtl.shp`       | RNCan / Hydro-Québec |

Renseigner aussi `arrondissement_pilote` dans `config.yaml`.

## 4. Charger les données dans PostGIS

```bash
python scripts/01_load_data.py
```

Toutes les couches (A, B, C) sont chargées en une seule passe.
Les couches absentes de `data/raw/` sont ignorées avec un avertissement.

## 5. Exécuter le pipeline SQL (Livrables A + B + C + contrôle qualité)

```bash
python scripts/02_run_sql_pipeline.py
```

Options utiles :
```bash
python scripts/02_run_sql_pipeline.py --from 08    # reprendre à l'étape ferroviaire
python scripts/02_run_sql_pipeline.py --only 10    # ne lancer que le QC Livrable C
```

## 6. Exporter les livrables finaux

```bash
python scripts/couche_combinee_uti_dedoublonnee.py   # Livrable A — couche consolidee finale
python scripts/03_export_gpkg.py                      # Export detail/reference (toutes couches uti.*)
```

Livrable A final : `data/processed/UTI_Routieres.gpkg`, produit par
`couche_combinee_uti_dedoublonnee.py` (couche maitresse dedupliquee
parterres/terre-pleins, cle config `sorties.uti_routieres_gpkg`). Ce script
consolide toutes les couches UTI en une seule couche denormalisee (l'epine
spatiale = l'emplacement) et exporte aussi une couche de controle unique
pour QGIS (`couche_maitresse_controle_unique`).

`03_export_gpkg.py` produit en complement un GeoPackage detail/reference,
`data/processed/UTI_Routieres_detail.gpkg` (cle config
`sorties.uti_routieres_detail_gpkg`) : une couche par table du schema `uti`
(socle + enrichissement) plus les références sources — utile pour
inspection/QGIS mais n'est plus le livrable final.

Deux GeoPackages supplementaires (inchanges) :
- `data/processed/UTI_Hydriques.gpkg` — Livrable B
- `data/processed/UTI_Infrastructures.gpkg` — Livrable C (ferroviaire + énergie)

## Ordre des étapes (correspond aux fichiers sql/)

| # | Fichier | Contenu |
|---|---------|---------|
| 00 | schema_extensions | Extensions PostGIS, schémas `raw`/`uti` |
| 01 | uti_routieres_polygones | Polygones nominatifs de rue (cadastre × UTG) |
| 02 | segmentation_troncons | Découpe en tronçons entre intersections |
| 03 | emplacements_parterres | Parterres pair/impair, terre-pleins |
| 04 | adresses_codes_postaux | Adresses et codes postaux par tronçon |
| 05 | surfaces_dimensions | Surfaces et longueurs |
| 06 | uti_hydriques | Buffers 30 m (RCG 24-008), lots riverains |
| 07 | controle_qualite | Vérifications Livrables A & B avant export |
| **08** | **uti_ferroviaires** | **Emprises ferro, gares, triage, buffers 30 m, lots touchés, conflits voirie** |
| **09** | **uti_energetiques** | **Lignes HT, gazoducs, postes, buffers 15 m, lots touchés, croisements** |
| **10** | **controle_qualite_infra** | **Vérifications Livrable C avant export** |

> **Note de numérotation (Livrable A).** Sur le jeu Montréal, l'enrichissement et
> les correctifs du Livrable A occupent en réalité les préfixes `10` à `14f` dans
> `sql/`. Vérifier la numérotation réelle du dossier avant tout `--only`. Le tableau
> ci-dessus décrit l'ossature générique A + B + C ; il ne remplace pas l'inventaire
> réel des fichiers.

## Correctifs Livrable A — série 14x (post-validation)

Conformément à la convention CARTHAB, aucun script numéroté validé n'est modifié :
les correctifs partent dans des fichiers suffixés, non destructifs et audités.

| Correctif | Objet | Effet mesuré |
|-----------|-------|--------------|
| `14c_fix_srid.sql` / `14c_bis_fix_srid_parterres.sql` | SRID 0 sur `uti.parterres.geom` et `uti.troncons_demis.geom` (défaut silencieux qui cassait les relations spatiales de la chaîne B). `14c` via `UPDATE ST_SetSRID` ; `14c_bis` via `DROP VIEW / ALTER COLUMN TYPE geometry(Polygon,2950) / CREATE VIEW` de `v_relations_actives`. | SRID **2950** rétabli partout ; aucune reprojection ; relations parterre ↔ lots à nouveau opérationnelles. |
| `14d_fix_arbres_hors_emprise.sql` | 19 arbres hors empreinte MTM8. | 1 récupéré (permutation X/Y), **18 marqués `hors_emprise = true`** (avec `geom_source` conservé) et exclus de l'export. |
| `14f_fix_arr_troncons.sql` | Propagation des arrondissements résolus par `09b` (`parterres.arr_appartenance`) vers `troncons_polygones.arr_gch`/`arr_drt`, par côté de rue (`impair → arr_gch`, `pair → arr_drt`). Valeurs d'origine conservées dans `arr_gch_src`/`arr_drt_src` ; `INCONNU` non propagé. | Tronçons **deux côtés `N/A` : 10 168 → 0** ; rues-limites UTG : **355 → 519** (dont **451** vraies frontières UTG-A + **68** `N/A` légitimes = bordures de villes liées hors territoire). |

Rejeu ciblé (exemples, préfixes littéraux triés alphabétiquement par le runner) :

```bash
python scripts/02_run_sql_pipeline.py --only 14c_bis
python scripts/02_run_sql_pipeline.py --only 14f
python scripts/06_verification_livrable_A.py   # socle 00–13b + 14c/14c_bis/14d/14f + étape 8
```

## Couches produites — Livrable C (UTI_Infrastructures.gpkg)

| Couche GeoPackage           | Description |
|-----------------------------|-------------|
| `ferro_emprises`            | Lignes ferroviaires + cours de triage (union normalisée) |
| `ferro_gares`               | Points de gares et stations |
| `ferro_cours_triage`        | Polygones des cours de triage avec surfaces |
| `ferro_buffers_30m`         | Zones tampon 30 m par type ferroviaire |
| `ferro_lots_touches`        | Lots cadastraux dans la zone tampon ferroviaire |
| `energie_lignes_ht`         | Lignes haute tension (Hydro-Québec TransÉnergie) |
| `energie_postes`            | Postes de transformation |
| `energie_gazoducs`          | Gazoducs (Énergir, Trans-Canada) |
| `energie_installations`     | Autres installations énergétiques |
| `energie_buffers_15m`       | Zones tampon 15 m par type énergétique |
| `energie_lots_touches`      | Lots cadastraux dans la zone tampon énergétique |
| `infra_conflits_routiers`   | Traversées ferroviaires × tronçons routiers |

## Points à valider sur vos données réelles avant de lancer

### Livrables A & B (inchangés)
- Le filtre `WHERE c.designation_lot ILIKE '%rue%'` (script 01) suppose un champ
  du cadastre identifiant les lots de voirie — à ajuster au nom réel du champ.
- La largeur de tampon de 25 m (script 02) est une hypothèse de demi-emprise.
- La détection des terre-pleins (script 03) reste manuelle.
- **[Résolu — Livrable A]** SRID 0 sur `uti.parterres` / `uti.troncons_demis` :
  corrigé par `14c` / `14c_bis` (SRID 2950 rétabli, sans reprojection). Vérifier
  toujours le SRID via `geometry_columns`, pas seulement à l'œil dans QGIS —
  un SRID 0 casse silencieusement les jointures spatiales.
- **[Résolu — Livrable A]** `arr_gch`/`arr_drt` à `'N/A'` sur `troncons_polygones` :
  propagés depuis les parterres par `14f`. Les `N/A` restants (~68) sont des
  bordures de villes liées hors territoire — légitimes, à documenter, pas à forcer.

### Livrable C — Ferroviaire (nouveau)
- Les champs `nom_ligne`, `exploitant`, `id_ligne` dans `raw.ferro_lignes` peuvent
  varier selon la source (RNCan vs OSM). Vérifier avec :
  `SELECT column_name FROM information_schema.columns WHERE table_name = 'ferro_lignes';`
- Ajuster les alias dans `08_uti_ferroviaires.sql` si les noms de champs diffèrent.
- Le buffer ferroviaire (30 m) peut être modifié via `buffer_ferroviaire_m` dans `config.yaml`
  (nécessite d'ajuster la valeur `30` dans le SQL en conséquence ou de paramétrer via une
  variable de session PostgreSQL).

### Livrable C — Énergie (nouveau)
- Les données RNCan couvrent l'ensemble du Canada ; filtrer sur l'emprise de Montréal
  avec `ogr2ogr -clipdst` ou en ajoutant un `WHERE ST_Within(geom, (SELECT geom FROM raw.perim_urb))`.
- Le buffer énergétique (15 m) est configurable via `buffer_energetique_m` dans `config.yaml`.
- Les gazoducs souterrains peuvent être absents des sources ouvertes — compléter avec
  les données d'Énergir si disponibles via entente.
