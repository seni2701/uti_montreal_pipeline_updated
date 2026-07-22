"""
verifier_mapping_arr.py  -- LECTURE SEULE. Verifie le mapping cote->arr_gch/arr_drt
AVANT de lancer 14f. Ne modifie RIEN.

Usage (racine du projet) :
    python scripts\verifier_mapping_arr.py
"""

import os
from sqlalchemy import create_engine, text


def env():
    try:
        from dotenv import load_dotenv
        load_dotenv()
    except Exception:
        pass
    if os.path.exists(".env"):
        for l in open(".env", encoding="utf-8-sig"):
            l = l.strip()
            if l and not l.startswith("#") and "=" in l:
                k, v = l.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def url():
    return (f"postgresql+psycopg2://{os.environ.get('DB_USER','ndoune')}:"
            f"{os.environ.get('DB_PASS','')}@{os.environ.get('DB_HOST','localhost')}:"
            f"{os.environ.get('DB_PORT','5432')}/{os.environ.get('DB_NAME','uti_montreal')}")


SQL = """
SELECT
  count(*) FILTER (WHERE p.arr_appartenance = t.arr_gch) AS impair_colle_a_gch,
  count(*) FILTER (WHERE p.arr_appartenance = t.arr_drt) AS impair_colle_a_drt
FROM uti.parterres p
JOIN uti.troncons_polygones t ON t.id_trc = p.id_trc
WHERE p.cote = 'impair'
  AND t.arr_gch <> 'N/A' AND t.arr_drt <> 'N/A'
  AND t.arr_gch <> t.arr_drt
  AND p.arr_appartenance NOT IN ('N/A','INCONNU');
"""


def main():
    env()
    with create_engine(url()).connect() as cx:
        r = cx.execute(text(SQL)).fetchone()
        gch, drt = r[0], r[1]
        print("\n=== CONTROLE DU MAPPING cote 'impair' -> arr_gch / arr_drt ===")
        print(f"  impair colle a arr_gch : {gch}")
        print(f"  impair colle a arr_drt : {drt}")
        print("-" * 55)
        if gch > drt * 5:
            print("  => MAPPING STANDARD confirme : impair = arr_gch, pair = arr_drt")
            print("     -> 14f est correct tel quel. Lancer 14f.")
        elif drt > gch * 5:
            print("  => MAPPING INVERSE : impair = arr_drt, pair = arr_gch")
            print("     -> PERMUTER [1] et [2] dans 14f AVANT de le lancer.")
        else:
            print("  => AMBIGU (pas de dominante nette). Ne pas lancer 14f :")
            print("     me coller ces chiffres, on inspecte au cas par cas.")


if __name__ == "__main__":
    main()
