-- ===========================================
-- Seed des roles, permissions et mappings
-- Execute automatiquement au premier demarrage
-- ===========================================

-- Attendre que Hibernate ait cree les tables (ce script tourne au init de Postgres,
-- donc les tables n'existent pas encore). On utilise une approche defensive.
-- Ce script sera aussi executable manuellement si besoin.

-- ==========================================
-- ROLES
-- ==========================================
INSERT INTO roles (name, display_name, description, created_at, updated_at) VALUES
    ('ADMIN', 'Administrateur', 'Acces complet a la plateforme', NOW(), NOW()),
    ('MANAGER', 'Manager', 'Gestion des operations et des equipes', NOW(), NOW()),
    ('HOST', 'Hote', 'Proprietaire de logements Airbnb', NOW(), NOW()),
    ('TECHNICIAN', 'Technicien', 'Intervient pour la maintenance et reparations', NOW(), NOW()),
    ('HOUSEKEEPER', 'Housekeeper', 'Effectue le nettoyage des logements', NOW(), NOW()),
    ('SUPERVISOR', 'Superviseur', 'Gere une equipe de techniciens/housekeepers', NOW(), NOW())
ON CONFLICT (name) DO NOTHING;

-- ==========================================
-- PERMISSIONS (35 permissions, 10 modules)
-- ==========================================
INSERT INTO permissions (name, description, module, created_at, updated_at) VALUES
    -- Dashboard
    ('dashboard:view', 'Voir le tableau de bord', 'dashboard', NOW(), NOW()),
    -- Properties
    ('properties:view', 'Voir les proprietes', 'properties', NOW(), NOW()),
    ('properties:create', 'Creer des proprietes', 'properties', NOW(), NOW()),
    ('properties:edit', 'Modifier des proprietes', 'properties', NOW(), NOW()),
    ('properties:delete', 'Supprimer des proprietes', 'properties', NOW(), NOW()),
    -- Service Requests
    ('service-requests:view', 'Voir les demandes', 'service-requests', NOW(), NOW()),
    ('service-requests:create', 'Creer des demandes', 'service-requests', NOW(), NOW()),
    ('service-requests:edit', 'Modifier des demandes', 'service-requests', NOW(), NOW()),
    ('service-requests:delete', 'Supprimer des demandes', 'service-requests', NOW(), NOW()),
    -- Interventions
    ('interventions:view', 'Voir les interventions', 'interventions', NOW(), NOW()),
    ('interventions:create', 'Creer des interventions', 'interventions', NOW(), NOW()),
    ('interventions:edit', 'Modifier des interventions', 'interventions', NOW(), NOW()),
    ('interventions:delete', 'Supprimer des interventions', 'interventions', NOW(), NOW()),
    -- Teams
    ('teams:view', 'Voir les equipes', 'teams', NOW(), NOW()),
    ('teams:create', 'Creer des equipes', 'teams', NOW(), NOW()),
    ('teams:edit', 'Modifier des equipes', 'teams', NOW(), NOW()),
    ('teams:delete', 'Supprimer des equipes', 'teams', NOW(), NOW()),
    -- Settings
    ('settings:view', 'Voir les parametres', 'settings', NOW(), NOW()),
    ('settings:edit', 'Modifier les parametres', 'settings', NOW(), NOW()),
    -- Users
    ('users:manage', 'Gerer les utilisateurs', 'users', NOW(), NOW()),
    ('users:view', 'Voir les utilisateurs', 'users', NOW(), NOW()),
    -- Reports
    ('reports:view', 'Voir les rapports', 'reports', NOW(), NOW()),
    ('reports:generate', 'Generer des rapports', 'reports', NOW(), NOW()),
    ('reports:download', 'Telecharger des rapports', 'reports', NOW(), NOW()),
    ('reports:manage', 'Gerer les rapports (admin)', 'reports', NOW(), NOW()),
    -- Portfolios
    ('portfolios:view', 'Voir les portefeuilles', 'portfolios', NOW(), NOW()),
    ('portfolios:create', 'Creer des portefeuilles', 'portfolios', NOW(), NOW()),
    ('portfolios:edit', 'Modifier des portefeuilles', 'portfolios', NOW(), NOW()),
    ('portfolios:delete', 'Supprimer des portefeuilles', 'portfolios', NOW(), NOW()),
    ('portfolios:manage_clients', 'Gerer les clients des portefeuilles', 'portfolios', NOW(), NOW()),
    ('portfolios:manage_team', 'Gerer les equipes des portefeuilles', 'portfolios', NOW(), NOW()),
    ('portfolios:manage', 'Gerer les portefeuilles', 'portfolios', NOW(), NOW()),
    -- Contact
    ('contact:view', 'Voir les messages de contact', 'contact', NOW(), NOW()),
    ('contact:send', 'Envoyer des messages de contact', 'contact', NOW(), NOW()),
    ('contact:manage', 'Gerer les messages de contact', 'contact', NOW(), NOW())
ON CONFLICT (name) DO NOTHING;

-- ==========================================
-- ROLE-PERMISSION MAPPINGS
-- ==========================================

-- ADMIN : TOUTES les permissions
INSERT INTO role_permissions (role_id, permission_id, is_default, is_active, created_at, updated_at)
SELECT r.id, p.id, true, true, NOW(), NOW()
FROM roles r CROSS JOIN permissions p
WHERE r.name = 'ADMIN'
AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id
);

-- MANAGER : tout sauf delete et users:manage
INSERT INTO role_permissions (role_id, permission_id, is_default, is_active, created_at, updated_at)
SELECT r.id, p.id, true, true, NOW(), NOW()
FROM roles r CROSS JOIN permissions p
WHERE r.name = 'MANAGER'
AND p.name NOT IN (
    'properties:delete', 'service-requests:delete', 'interventions:delete',
    'teams:delete', 'users:manage', 'portfolios:delete', 'reports:manage', 'contact:manage'
)
AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id
);

-- HOST
INSERT INTO role_permissions (role_id, permission_id, is_default, is_active, created_at, updated_at)
SELECT r.id, p.id, true, true, NOW(), NOW()
FROM roles r CROSS JOIN permissions p
WHERE r.name = 'HOST'
AND p.name IN (
    'dashboard:view', 'properties:view', 'properties:create', 'properties:edit',
    'service-requests:view', 'service-requests:create', 'interventions:view',
    'portfolios:view', 'reports:view'
)
AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id
);

-- TECHNICIAN
INSERT INTO role_permissions (role_id, permission_id, is_default, is_active, created_at, updated_at)
SELECT r.id, p.id, true, true, NOW(), NOW()
FROM roles r CROSS JOIN permissions p
WHERE r.name = 'TECHNICIAN'
AND p.name IN (
    'dashboard:view', 'interventions:view', 'interventions:edit', 'teams:view'
)
AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id
);

-- HOUSEKEEPER
INSERT INTO role_permissions (role_id, permission_id, is_default, is_active, created_at, updated_at)
SELECT r.id, p.id, true, true, NOW(), NOW()
FROM roles r CROSS JOIN permissions p
WHERE r.name = 'HOUSEKEEPER'
AND p.name IN (
    'dashboard:view', 'interventions:view', 'interventions:edit', 'teams:view'
)
AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id
);

-- SUPERVISOR
INSERT INTO role_permissions (role_id, permission_id, is_default, is_active, created_at, updated_at)
SELECT r.id, p.id, true, true, NOW(), NOW()
FROM roles r CROSS JOIN permissions p
WHERE r.name = 'SUPERVISOR'
AND p.name IN (
    'dashboard:view', 'interventions:view', 'interventions:edit',
    'teams:view', 'teams:edit', 'portfolios:view',
    'reports:view', 'reports:generate', 'reports:download'
)
AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id
);
