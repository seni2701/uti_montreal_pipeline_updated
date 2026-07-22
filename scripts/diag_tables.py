import psycopg2

conn = psycopg2.connect("VOTRE_CHAINE_DE_CONNEXION")
cur = conn.cursor()
cur.execute("""
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
    ORDER BY 1, 2
""")
for row in cur.fetchall():
    print(row)
cur.close()
conn.close()