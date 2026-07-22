import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from utils.db import get_engine
from sqlalchemy import text

engine = get_engine()
with engine.connect() as cx:
    rows = cx.execute(text("""
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'raw'
        ORDER BY table_name
    """)).fetchall()
    print("=== TABLES DU SCHEMA raw ===")
    for r in rows:
        print(r[0])

    # Si raw.cadastre existe, afficher ses colonnes
    if any(r[0] == 'cadastre' for r in rows):
        cols = cx.execute(text("""
            SELECT column_name FROM information_schema.columns
            WHERE table_schema='raw' AND table_name='cadastre'
        """)).fetchall()
        print("\n=== COLONNES DE raw.cadastre ===")
        for c in cols:
            print(c[0])
