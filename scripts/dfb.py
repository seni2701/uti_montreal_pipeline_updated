# inspect_schema.py  (jetable — ne pas verser dans sql/)
import yaml
from sqlalchemy import create_engine, text

cfg = yaml.safe_load(open("config.yaml", encoding="utf-8"))
# adapter la clé selon ton config.yaml (souvent cfg["database"]["url"] ou équivalent)
engine = create_engine(cfg["database"]["url"])

q1 = """
SELECT table_name, column_name
FROM information_schema.columns
WHERE column_name IN ('nb_adresses','taux_geocodage','deb_gch','deb_drt','code_postal')
  AND table_schema = 'uti'
ORDER BY table_name, column_name;
"""
q2 = """
SELECT f_table_name, type, srid
FROM geometry_columns
WHERE f_table_schema = 'uti'
ORDER BY f_table_name;
"""
with engine.connect() as cx:
    print("=== Colonnes attributaires ===")
    for r in cx.execute(text(q1)):
        print(r)
    print("\n=== Tables géométriques uti ===")
    for r in cx.execute(text(q2)):
        print(r)