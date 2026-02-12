#!/bin/bash

# Attendre que Keycloak soit prêt
echo "Waiting for Keycloak to be ready..."
until curl -s http://keycloak:8080/realms/master > /dev/null; do
    echo "Waiting for Keycloak..."
    sleep 5
done

echo "Keycloak is ready!"

# Obtenir le token d'accès admin
echo "Getting admin access token..."
TOKEN_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" \
    -d "password=admin" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    http://keycloak:8080/realms/master/protocol/openid-connect/token)

# Extraire le token sans jq
ADMIN_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$ADMIN_TOKEN" ]; then
    echo "Failed to get admin token"
    echo "Response: $TOKEN_RESPONSE"
    exit 1
fi

echo "Admin token obtained successfully"

# Créer l'utilisateur admin dans le realm clenzy
echo "Creating admin user in clenzy realm..."
USER_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "username": "admin",
        "enabled": true,
        "email": "admin@clenzy.fr",
        "emailVerified": true,
        "firstName": "Admin",
        "lastName": "User",
        "credentials": [{
            "type": "password",
            "value": "admin",
            "temporary": false
        }]
    }' \
    http://keycloak:8080/admin/realms/clenzy/users)

echo "User creation response: $USER_RESPONSE"

# Attendre un peu pour que l'utilisateur soit créé
sleep 2

# Assigner le rôle ADMIN à l'utilisateur
echo "Getting user ID..."
USERS_RESPONSE=$(curl -s -X GET \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    "http://keycloak:8080/admin/realms/clenzy/users?username=admin")

echo "Users response: $USERS_RESPONSE"

# Extraire l'ID utilisateur sans jq
USER_ID=$(echo "$USERS_RESPONSE" | grep -o '"[^"]*"' | head -1 | tr -d '"')

if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
    echo "User ID: $USER_ID"
    
    # Obtenir le rôle ADMIN
    echo "Getting ADMIN role..."
    ROLE_RESPONSE=$(curl -s -X GET \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        "http://keycloak:8080/admin/realms/clenzy/roles/ADMIN")
    
    echo "Role response: $ROLE_RESPONSE"
    
    # Extraire l'ID du rôle sans jq
    ROLE_ID=$(echo "$ROLE_RESPONSE" | grep -o '"[^"]*"' | head -1 | tr -d '"')
    
    if [ -n "$ROLE_ID" ] && [ "$ROLE_ID" != "null" ]; then
        echo "Role ID: $ROLE_ID"
        
        # Assigner le rôle
        echo "Assigning ADMIN role to user..."
        ROLE_ASSIGNMENT_RESPONSE=$(curl -s -X POST \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d "[{\"id\":\"$ROLE_ID\",\"name\":\"ADMIN\"}]" \
            "http://keycloak:8080/admin/realms/clenzy/users/$USER_ID/role-mappings/realm")
        
        echo "Role assignment response: $ROLE_ASSIGNMENT_RESPONSE"
        echo "Role assignment completed"
    else
        echo "Failed to get ADMIN role"
    fi
else
    echo "Failed to get user ID"
fi

echo "Keycloak initialization completed!"
