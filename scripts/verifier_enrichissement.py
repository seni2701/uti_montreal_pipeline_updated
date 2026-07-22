"""
verifier_enrichissement.py
Controle qualite des enrichissements du Livrable A (scripts 10-13 + correctifs).
Genere un rapport au format de reports/verification_livrable_A.txt.

Usage :
    python scripts/verifier_enrichissement.py
"""
from datetime import datetime
from pathlib import Path
import pandas as pd
from utils.db import get_engine

ROOT = Path(__file__).resolve().parents[1]
OUT  = ROOT / "reports" / "verification_enrichissement.txt"

SEP  = "=" * 70
SUB  = "-" * 70

def main():
    e = get_engine()
    lines, ok, warn = [], 0, 0

    def scalar(q) -> int:
        # str() avant int() : lève l'ambiguité de type Scalar (Pylance)
        return int(str(pd.read_sql(q, e).iloc[0, 0]))

    def table(q):
        return pd.read_sql(q, e)

    def add(msg=""):
        lines.append(msg)

    def check(label, value, status=None):
        nonlocal ok, warn
        add(f"> {label}")
        add(f"  -> {value}")
        if status == "OK":   ok += 1;   add("  [OK]")
        if status == "WARN": warn += 1; add("  [WARN]")
        add()

    add(SEP)
    add("  RAPPORT DE VERIFICATION — ENRICHISSEMENT LIVRABLE A")
    add(f"  Genere le : {datetime.now():%Y-%m-%d %H:%M:%S}")
    add("  Mandat    : Treevans / Transport Montreal 2026")
    add("  Portee    : composantes voirie, cyclable, arbres, interferences, colonnes")
    add(SEP); add()

    # --- 1. Composantes de voirie -------------------------------------------
    add(SUB); add("1 — COMPOSANTES DE VOIRIE (uti.composantes_voirie)"); add(SUB)
    tot = scalar("SELECT count(*) FROM uti.composantes_voirie")
    nn  = scalar("SELECT count(*) FROM uti.composantes_voirie WHERE id_trc IS NULL")
    check("Nb total de composantes", tot, "OK" if tot > 0 else "WARN")
    add("> Repartition par type"); add(table(
        "SELECT type_composante, count(*) FROM uti.composantes_voirie GROUP BY 1 ORDER BY 2 DESC"
    ).to_string(index=False)); add()
    pct = round(100*nn/tot, 1) if tot else 0
    check(f"Composantes non rattachees a un troncon ({pct}%)", nn,
          "OK" if pct < 5 else "WARN")

    # --- 2. Pistes cyclables ------------------------------------------------
    add(SUB); add("2 — RESEAU CYCLABLE (uti.pistes_cyclables)"); add(SUB)
    add("> Rattachement"); add(table(
        "SELECT methode_rattachement, count(*) FROM uti.pistes_cyclables GROUP BY 1 ORDER BY 2 DESC"
    ).to_string(index=False)); add()
    tot_c = scalar("SELECT count(*) FROM uti.pistes_cyclables")
    nr_c  = scalar("SELECT count(*) FROM uti.pistes_cyclables WHERE methode_rattachement='non_rattache'")
    pct_c = round(100*nr_c/tot_c, 1) if tot_c else 0
    check(f"Segments non rattaches ({pct_c}%)", nr_c, "OK" if pct_c < 10 else "WARN")

    # --- 3. Arbres ----------------------------------------------------------
    add(SUB); add("3 — COMPOSANTES NATURELLES (uti.arbres)"); add(SUB)
    tot_a = scalar("SELECT count(*) FROM uti.arbres")
    ratt  = scalar("SELECT count(*) FROM uti.arbres WHERE methode_rattachement <> 'non_rattache'")
    pct_a = round(100*ratt/tot_a, 1) if tot_a else 0
    add("> Rattachement"); add(table(
        "SELECT methode_rattachement, count(*) FROM uti.arbres GROUP BY 1 ORDER BY 2 DESC"
    ).to_string(index=False)); add()
    check(f"Arbres rattaches a un emplacement ({pct_a}%)", ratt,
          "OK" if pct_a >= 80 else "WARN")
    check("Volume de la source (attendu ~330 000, 13 arrond. corporatifs)", tot_a,
          "OK" if tot_a >= 50000 else "WARN")
    dhp = scalar("SELECT count(*) FROM uti.arbres WHERE dhp_cm IS NOT NULL")
    check("Arbres avec DHP numerique exploitable", f"{dhp} / {tot_a}",
          "WARN" if dhp < tot_a*0.9 else "OK")

    # --- 4. Interferences ---------------------------------------------------
    add(SUB); add("4 — REPERTOIRE INFRASTRUCTURES (uti.interferences_troncon)"); add(SUB)
    add("> Par categorie"); add(table(
        "SELECT categorie, count(*) FROM uti.interferences_troncon GROUP BY 1 ORDER BY 2 DESC"
    ).to_string(index=False)); add()
    add("> Non rattachees par categorie"); add(table(
        "SELECT categorie, count(*) AS non_rattachees FROM uti.interferences_troncon "
        "WHERE id_trc IS NULL GROUP BY 1 ORDER BY 2 DESC"
    ).to_string(index=False)); add()
    tot_i = scalar("SELECT count(*) FROM uti.interferences_troncon")
    check("Nb total d'interferences documentees", tot_i, "OK" if tot_i > 0 else "WARN")

    # --- 5. Parterres enrichis ----------------------------------------------
    add(SUB); add("5 — ENRICHISSEMENT DES PARTERRES (uti.parterres)"); add(SUB)
    rs = scalar("SELECT count(*) FROM uti.parterres WHERE rang_surface IS NOT NULL")
    tp = scalar("SELECT count(*) FROM uti.parterres")
    check("Parterres avec rang_surface calcule", f"{rs} / {tp}",
          "OK" if rs == tp else "WARN")
    add("> Drapeaux (comptes)"); add(table(
        "SELECT count(*) FILTER (WHERE presence_trottoir) AS trottoir, "
        "count(*) FILTER (WHERE presence_saillie) AS saillie, "
        "count(*) FILTER (WHERE presence_piste_cyclable) AS piste, "
        "count(*) FILTER (WHERE nb_arbres>0) AS avec_arbres, "
        "count(*) FILTER (WHERE flag_multi_parterre) AS multi FROM uti.parterres"
    ).to_string(index=False)); add()

    # --- 6. Relations lots --------------------------------------------------
    add(SUB); add("6 — RELATIONS LOTS (uti.troncons_lots)"); add(SUB)
    act = scalar("SELECT count(*) FROM uti.troncons_lots WHERE actif")
    check("Relations actives (attendu > 0)", act, "OK" if act > 0 else "WARN")
    add("> Profils d'acces"); add(table(
        "SELECT profil_acces, count(*) FROM uti.troncons_lots GROUP BY 1 ORDER BY 2 DESC"
    ).to_string(index=False)); add()

    # --- 7. Couverture geocodage (pas un taux : une couverture) --------------
    add(SUB); add("7 — COUVERTURE ADRESSES (uti.troncons_adresses)"); add(SUB)
    tt   = scalar("SELECT count(*) FROM uti.troncons_adresses")
    couv = scalar("SELECT count(*) FROM uti.troncons_adresses WHERE taux_geocodage IS NOT NULL")
    pct_g = round(100*couv/tt, 1) if tt else 0
    add("  NOTE : taux_geocodage vaut 1.0 partout (dist_m toujours renseigne) ;")
    add("         seule la COUVERTURE (troncon avec >=1 adresse) est significative.")
    check(f"Troncons avec au moins une adresse ({pct_g}%)", f"{couv} / {tt}",
          "OK" if pct_g >= 60 else "WARN")

    # --- Resume -------------------------------------------------------------
    add(SEP); add("  RESUME DE CONFORMITE")
    add(SEP)
    add(f"  [OK]    Criteres satisfaits     : {ok}")
    add(f"  [WARN]  Avertissements          : {warn}")
    add(SEP)
    add()
    add("Notes (limites de donnees, non bloquantes) :")
    add("  - Arbres : couverture limitee aux arrondissements du systeme corporatif ;")
    add("    Montreal-Nord et Outremont sont diffuses a part. Localisation parfois imprecise.")
    add("  - taux_geocodage non significatif : utiliser la couverture adresses.")

    report = "\n".join(lines)
    print(report)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(report, encoding="utf-8")
    print(f"\n[ecrit] {OUT}")

if __name__ == "__main__":
    main()