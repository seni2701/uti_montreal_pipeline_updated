import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from utils.db import get_engine
from sqlalchemy import text

engine = get_engine()
candidats = ["g_co_typ_2", "g_co_indic", "g_co_echel", "g_co_ech_1", "g_co_ech_2"]

with engine.connect() as cx:
    for col in candidats:
        print(f"\n=== Valeurs distinctes de raw.cadastre.{col} (top 20) ===")
        try:
            rows = cx.execute(text(f"""
                SELECT {col}, count(*) AS n
                FROM raw.cadastre
                GROUP BY {col}
                ORDER BY n DESC
                LIMIT 20
            """)).fetchall()
            for r in rows:
                print(r)
        except Exception as e:
            print(f"  [erreur] {e}")
