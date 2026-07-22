import argparse, re, sys
from pathlib import Path
from sqlalchemy import text
from utils.db import get_engine

ROOT    = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"

def sql_files():
    return sorted([f for f in SQL_DIR.glob("*.sql") if f.suffix == ".sql"],
                  key=lambda p: p.name)

def split_statements(sql):
    # On retire les lignes de commentaire (--) ET les meta-commandes psql (\set, \i, \echo...)
    # car ce runner envoie le SQL via SQLAlchemy, pas via le client psql.
    lines = [l for l in sql.splitlines()
             if not l.strip().startswith("--")
             and not l.strip().startswith("\\")]
    txt, s, cur, ind, dt, i = "\n".join(lines), [], [], False, "", 0
    while i < len(txt):
        m = re.match(r"\$([^$\s]*)\$", txt[i:])
        if m:
            tag = m.group(0)
            if not ind:
                ind, dt = True, tag
                cur.append(tag); i += len(tag); continue
            elif txt[i:i+len(dt)] == dt:
                ind, dt = False, ""
                cur.append(tag); i += len(tag); continue
        ch = txt[i]
        if ch == ";" and not ind:
            st = "".join(cur).strip()
            if st: s.append(st)
            cur = []
        else:
            cur.append(ch)
        i += 1
    st = "".join(cur).strip()
    if st: s.append(st)
    return s

def main():
    p = argparse.ArgumentParser(
        description="Execute les scripts sql/*.sql dans l'ordre alphabetique.",
        epilog="""Exemples :
  python scripts/02_run_sql_pipeline.py              -> tout executer
  python scripts/02_run_sql_pipeline.py --from 06   -> a partir de 06_*
  python scripts/02_run_sql_pipeline.py --to 09b    -> jusqu'a 09b_* inclus
  python scripts/02_run_sql_pipeline.py --only 05b  -> uniquement 05b_*
  python scripts/02_run_sql_pipeline.py --from 10 --to 13  -> enrichissements 10 a 13"""
    )
    p.add_argument("--from", dest="from_prefix", default=None,
                   help="Prefixe de depart (ex: 06, 05b, 10)")
    p.add_argument("--to",   dest="to_prefix",   default=None,
                   help="Prefixe d'arret inclus (ex: 09, 09b, 13)")
    p.add_argument("--only", dest="only_prefix", default=None,
                   help="Executer un seul fichier (ex: 05b, 12)")
    p.add_argument("--list", dest="list_only",   action="store_true",
                   help="Lister les fichiers sans les executer")
    a = p.parse_args()

    files = sql_files()

    if a.only_prefix:
        files = [f for f in files if f.name.startswith(a.only_prefix)]
    else:
        if a.from_prefix:
            files = [f for f in files if f.name >= a.from_prefix]
        if a.to_prefix:
            # Comparaison prefixe : "09b" <= "09b_fix..." -> inclus
            # "10"  >  "09b_fix..." -> exclu
            files = [f for f in files
                     if f.name[:max(len(a.to_prefix), 2)] <= a.to_prefix
                     or f.name.startswith(a.to_prefix)]

    if not files:
        print("Aucun fichier SQL trouve pour ces criteres.")
        all_files = sql_files()
        print(f"Fichiers disponibles dans {SQL_DIR} :")
        for f in all_files:
            print(f"  {f.name}")
        sys.exit(1)

    # Affichage du plan d'execution
    SEP = "-" * 50
    print(SEP)
    print(f"Plan d'execution ({len(files)} fichier(s)) :")
    for f in files:
        print(f"  {f.name}")
    print(SEP)

    if a.list_only:
        print("(mode --list : aucune execution)")
        sys.exit(0)

    engine = get_engine()
    ok_count = 0

    for f in files:
        print(f"\n--- {f.name} ---")
        stmts = split_statements(f.read_text(encoding="utf-8"))
        print(f"    {len(stmts)} statement(s) detecte(s)")
        with engine.begin() as conn:
            try:
                for stmt in stmts:
                    conn.execute(text(stmt))
            except Exception as e:
                print(f"[ERREUR] {f.name} : {e}")
                sys.exit(1)
        print(f"[ok] {f.name}")
        ok_count += 1

    print(f"\n{SEP}")
    print(f"Pipeline termine — {ok_count}/{len(files)} fichier(s) executes avec succes.")
    print(SEP)

if __name__ == "__main__":
    main()