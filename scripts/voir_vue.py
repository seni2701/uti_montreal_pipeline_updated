import os
from sqlalchemy import create_engine, text

if os.path.exists(".env"):
    for l in open(".env", encoding="utf-8-sig"):
        l = l.strip()
        if l and not l.startswith("#") and "=" in l:
            k, v = l.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

url = (f"postgresql+psycopg2://{os.environ['DB_USER']}:{os.environ['DB_PASS']}"
       f"@{os.environ['DB_HOST']}:{os.environ['DB_PORT']}/{os.environ['DB_NAME']}")

with create_engine(url).connect() as cx:
    print("=== DEFINITION DE LA VUE v_relations_actives ===")
    print(cx.execute(text("SELECT pg_get_viewdef('uti.v_relations_actives'::regclass, true)")).scalar())
    print("\n=== TYPE GEOMETRIQUE DES PARTERRES ===")
    for r in cx.execute(text(
        "SELECT GeometryType(geom), count(*) FROM uti.parterres GROUP BY GeometryType(geom)")):
        print(" ", r[0], "|", r[1])