-- ===========================================
-- Initialisation des bases de données Clenzy
-- ===========================================
-- Ce script crée les bases nécessaires au démarrage :
-- 1. clenzy_dev   → Application PMS
-- 2. keycloak_dev → Keycloak Identity Provider

-- Création de la base Keycloak (si elle n'existe pas)
SELECT 'CREATE DATABASE keycloak_dev OWNER clenzy'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak_dev')\gexec
