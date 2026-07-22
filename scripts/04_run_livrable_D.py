"""
04_run_livrable_D.py
--------------------
Orchestrateur de la chaîne complète UTI-T2H ÉLECTRIQUE (Livrable D).

Enchaîne, dans l'ordre, et s'arrête au premier échec :

  SOCLE (produit) :
    1. 01b_load_energie.py                  -> raw.elec_*
    2. 01c_load_zonage_foncier.py           -> raw.affectation_pum, raw.role_foncier
    3. sql/15_uti_hydroelectriques.sql      -> DDL (structure)
    4. sql/15b_fix_pylones_geom.sql         -> pylônes polygonaux + journal
    5. sql/15c_stub_emprises_hq.sql         -> stub HQ (absence tracée)
    6. sql/16_populate_t2h_elec.sql         -> lignes, pylônes, rattachement
    7. sql/16b_fix_niveau_pylone.sql        -> niveau PYLONE + candidats postes
    8. sql/16c_corridors_t2h_elec.sql       -> 23 corridors (unité de découpage)
    9. sql/16d_couche_maitresse_t2h_combinee.sql -> couche combinée multi-niveaux
   10. sql/17_foncier_regime.sql            -> table régime foncier + fonction
   11. sql/17b_foncier_regime_complement.sql -> complément série 8xxx

  CHAÎNE RÉGLEMENTAIRE (dort tant que la tension HQ est absente) :
   12. sql/18_populate_emprises.sql         -> emprises (buffer sur corridor)
   13. sql/19_populate_sections.sql         -> sections (affectation x foncier)
   14. sql/20_emplacements.sql              -> emplacements et cohabitation
   15. sql/20b_utg.sql                      -> référentiel UTG et rattachement

Puis affiche le rapport : avancement par étape + journal des blocages.

Usage :
    python scripts/04_run_livrable_D.py
    python scripts/04_run_livrable_D.py --skip-load    # SQL seulement
    python scripts/04_run_livrable_D.py --dry-run      # plan sans exécution

Convention CARTHAB : aucun script numéroté n'est modifié. Cet orchestrateur ne
fait que les appeler dans l'ordre. La logique métier reste dans les fichiers SQL.
"""

import argparse
import subprocess
import sys
from pathlib import Path

from sqlalchemy import text

from utils.db import get_engine

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
PY = sys.executable

SEP = "=" * 74

# (titre, [script python] ou None, préfixe SQL ou None)
ETAPES = [
    ("Chargement sources énergie",       ["01b_load_energie.py"],        None),
    ("Chargement zonage + foncier",      ["01c_load_zonage_foncier.py"], None),
    ("DDL — structure T2H",              None, "15_"),
    ("Référentiels réglementaires",      None, "16_"),
    ("Socle géométrique et tension",     None, "17_"),
    ("Emprises aérienne et sol",         None, "18"),
    ("Sections par zonage et foncier",   None, "19"),
    ("Emplacements et cohabitation",     None, "20_"),
    ("Unités territoriales de gestion",  None, "20b"),
    ("Couche maîtresse livrable",        None, "21_"),
    ("Vues de contrôle",                 None, "21b"),
    ("Incursions et interférences",      None, "22"),
]


def lancer(cmd, titre):
    print(f"\n{SEP}\n>>> {titre}\n{SEP}")
    r = subprocess.run(cmd, cwd=ROOT)
    if r.returncode != 0:
        print(f"\n[ÉCHEC] {titre} — code {r.returncode}. Chaîne interrompue.")
        sys.exit(r.returncode)


def rapport():
    print(f"\n{SEP}\n>>> RAPPORT — Livrable D (UTI Hydroélectriques)\n{SEP}")

    engine = get_engine()
    with engine.connect() as c:

        print("\nAvancement de la chaîne :\n")
        print(f"  {'ÉTAPE':<16}{'VOLUME':>10}   STATUT")
        print(f"  {'-' * 40}")
        for etape, n, statut in c.execute(text(
            "SELECT etape, n, statut FROM uti.v_t2h_elec_avancement ORDER BY ordre"
        )).fetchall():
            marque = "[OK]  " if statut == "OK" else "[BLOQ]"
            print(f"  {etape:<16}{n:>10,}   {marque} {statut}")

        print("\nJournal des blocages :\n")
        rows = c.execute(text("""
            SELECT severite, etape, motif, action_requise
            FROM uti.t2h_elec_journal_blocages
            ORDER BY CASE severite
                        WHEN 'BLOQUANT' THEN 1
                        WHEN 'AVERTISSEMENT' THEN 2
                        ELSE 3 END, etape
        """)).fetchall()

        if not rows:
            print("  Aucun blocage. La chaîne est complète.")
        else:
            for sev, etape, motif, action in rows:
                print(f"  [{sev}] {etape}")
                print(f"      Motif  : {motif}")
                if action:
                    print(f"      Action : {action}")
                print()

        n_bloq = sum(1 for r in rows if r[0] == "BLOQUANT")

    print(SEP)
    if n_bloq:
        print(f"Chaîne exécutée. {n_bloq} blocage(s) BLOQUANT — livrable INCOMPLET.")
        print("Le socle géométrique (lignes, pylônes, corridors) et toute la logique")
        print("réglementaire (emprises, sections, emplacements) sont EN PLACE. Cette")
        print("dernière dort en attendant un seul intrant : la tension nominale HQ.")
        print("Le jour du déblocage : charger la tension, passer la règle TRANSPORT à")
        print("VALIDE, relancer ce script — la chaîne se complète sans modification.")
    else:
        print("Chaîne exécutée sans blocage — livrable COMPLET.")
    print(SEP)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--skip-load", action="store_true",
                    help="ne pas relancer les chargements python (SQL seulement)")
    ap.add_argument("--dry-run", action="store_true",
                    help="afficher le plan sans rien exécuter")
    args = ap.parse_args()

    print(SEP)
    print("Livrable D — UTI Hydroélectriques (T2H électrique)")
    print(SEP)
    print("\nPlan d'exécution :\n")
    for i, (titre, script, prefixe) in enumerate(ETAPES, 1):
        est_load = prefixe is None
        suffixe = "  [IGNORÉ : --skip-load]" if (args.skip_load and est_load) else ""
        print(f"  {i:>2}. {titre}{suffixe}")

    if args.dry_run:
        print("\n(mode --dry-run : aucune exécution)")
        return

    for titre, script, prefixe in ETAPES:
        if prefixe is None:
            if args.skip_load:
                continue
            lancer([PY, str(SCRIPTS / script[0])], titre)
        else:
            lancer([PY, str(SCRIPTS / "02_run_sql_pipeline.py"),
                    "--only", prefixe], titre)

    rapport()


if __name__ == "__main__":
    main()