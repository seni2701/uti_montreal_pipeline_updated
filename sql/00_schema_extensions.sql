-- 00_schema_extensions.sql
-- Initialise les extensions et l'organisation des schémas.
-- Convention : ce fichier numéroté n'est jamais modifié après une première exécution réussie.
-- Tout correctif va dans un script séparé (ex. 00b_fix_xxx.sql), jamais ici.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;

CREATE SCHEMA IF NOT EXISTS raw;   -- données sources, telles que chargées (lecture seule en pratique)
CREATE SCHEMA IF NOT EXISTS uti;  -- livrables et tables de travail du projet UTI

COMMENT ON SCHEMA raw IS 'Données ouvertes chargées telles que reçues (cadastre, réseau, hydrique, etc.)';
COMMENT ON SCHEMA uti IS 'Livrable A (UTI Routières) et Livrable B (UTI Hydriques) — contrat IAER/Treevans';
