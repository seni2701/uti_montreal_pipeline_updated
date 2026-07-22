# inspect_view.py — à lancer une seule fois pour récupérer la définition
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from utils.db import get_engine
from sqlalchemy import text

engine = get_engine()
with engine.connect() as conn:
    result = conn.execute(text(
        "SELECT pg_get_viewdef('uti.v_rues_limites_utg'::regclass, true)"
    ))
    print(result.scalar())

    print("\n--- Toutes les vues du schéma uti ---")
    result = conn.execute(text(
        "SELECT viewname FROM pg_views WHERE schemaname = 'uti'"
    ))
    for row in result:
        print(row[0])