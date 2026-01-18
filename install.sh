#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}INFO: $1${NC}"
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Step 1: Check if .env file exists
info "Checking for .env file..."
if [ ! -f .env ]; then
    error_exit "There is no .env file, please create it"
fi

# Step 2: Load and verify REGISTRY_DOMAIN
info "Loading .env file..."
source .env

if [ -z "$REGISTRY_DOMAIN" ]; then
    warn "REGISTRY_DOMAIN is not set in .env file"
    read -p "Please enter the registry domain (e.g., registry.example.com): " REGISTRY_DOMAIN
    
    if [ -z "$REGISTRY_DOMAIN" ]; then
        error_exit "REGISTRY_DOMAIN must not be empty"
    fi
    
    # Update .env file with the provided domain
    if grep -q "^REGISTRY_DOMAIN=" .env; then
        sed -i.bak "s/^REGISTRY_DOMAIN=.*/REGISTRY_DOMAIN=$REGISTRY_DOMAIN/" .env
        rm -f .env.bak
    else
        echo "REGISTRY_DOMAIN=$REGISTRY_DOMAIN" >> .env
    fi
    info "REGISTRY_DOMAIN saved to .env file"
fi

info "Using REGISTRY_DOMAIN: $REGISTRY_DOMAIN"

# Step 3: Generate SSL certificate if not exists
SSL_CERT="ssl/registry.crt"
SSL_KEY="ssl/registry.key"

if [ -f "$SSL_CERT" ] && [ -f "$SSL_KEY" ]; then
    info "SSL certificate and key already exist, skipping generation"
else
    info "Generating self-signed SSL certificate..."
    
    # Ensure ssl directory exists
    mkdir -p ssl
    
    # Prompt for certificate details
    read -p "Country Name (2 letter code) [US]: " COUNTRY
    COUNTRY=${COUNTRY:-US}
    
    read -p "State or Province Name [California]: " STATE
    STATE=${STATE:-California}
    
    read -p "Locality Name (city) [San Francisco]: " CITY
    CITY=${CITY:-San Francisco}
    
    read -p "Organization Name [My Company]: " ORG
    ORG=${ORG:-My Company}
    
    read -p "Organizational Unit Name [IT Department]: " OU
    OU=${OU:-IT Department}
    
    read -p "Email Address [admin@${REGISTRY_DOMAIN}]: " EMAIL
    EMAIL=${EMAIL:-admin@${REGISTRY_DOMAIN}}
    
    # Generate SSL certificate
    openssl req -newkey rsa:4096 -nodes -sha256 \
        -keyout "$SSL_KEY" \
        -x509 -days 365 \
        -out "$SSL_CERT" \
        -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=$REGISTRY_DOMAIN/emailAddress=$EMAIL"
    
    info "SSL certificate generated successfully"
fi

# Step 4: Set permissions on SSL files
info "Setting permissions on SSL files..."
if [ -f "$SSL_CERT" ]; then
    chmod 600 "$SSL_CERT"
fi
if [ -f "$SSL_KEY" ]; then
    chmod 600 "$SSL_KEY"
fi
info "SSL file permissions set to 600"

# Step 5: Check if htpasswd utility exists
if ! command -v htpasswd &> /dev/null; then
    error_exit "You must install htpasswd to be continued"
fi

# Step 6: Create htpasswd file if not exists or is empty
HTPASSWD_FILE="auth/htpasswd"

# Ensure auth directory exists
mkdir -p auth

if [ -f "$HTPASSWD_FILE" ] && [ -s "$HTPASSWD_FILE" ]; then
    info "htpasswd file already exists with users, skipping creation"
    read -p "Do you want to add another user? (y/N): " ADD_USER
    ADD_USER=${ADD_USER:-N}
    
    if [[ "$ADD_USER" =~ ^[Yy]$ ]]; then
        read -p "Enter username: " USERNAME
        if [ -z "$USERNAME" ]; then
            error_exit "Username must not be empty"
        fi
        
        htpasswd -B "$HTPASSWD_FILE" "$USERNAME"
        info "User '$USERNAME' added to htpasswd file"
    fi
else
    info "Creating htpasswd file..."
    read -p "Enter username for registry authentication: " USERNAME
    
    if [ -z "$USERNAME" ]; then
        error_exit "Username must not be empty"
    fi
    
    # Create htpasswd file with user
    htpasswd -c -B "$HTPASSWD_FILE" "$USERNAME"
    info "htpasswd file created with user '$USERNAME'"
fi

# Step 7: Set proper permissions on auth directory and htpasswd file
info "Setting permissions on auth directory and htpasswd file..."
chmod 755 auth/
if [ -f "$HTPASSWD_FILE" ]; then
    chmod 644 "$HTPASSWD_FILE"
    info "htpasswd file permissions set to 644"
fi

# Step 8: Ensure data directory exists
mkdir -p data/
chmod 755 data/

# Step 9: Verify all required files exist before starting
info "Verifying required files..."
if [ ! -f "$SSL_CERT" ]; then
    error_exit "SSL certificate not found at $SSL_CERT"
fi
if [ ! -f "$SSL_KEY" ]; then
    error_exit "SSL key not found at $SSL_KEY"
fi
if [ ! -f "$HTPASSWD_FILE" ]; then
    error_exit "htpasswd file not found at $HTPASSWD_FILE"
fi
if [ ! -s "$HTPASSWD_FILE" ]; then
    error_exit "htpasswd file is empty at $HTPASSWD_FILE"
fi
info "✓ All required files are present and valid"

# Step 10: Determine which docker compose command to use
info "Detecting Docker Compose command..."
if command -v docker &> /dev/null && docker compose version &> /dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
    info "Using 'docker compose'"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
    info "Using 'docker-compose'"
else
    error_exit "Neither 'docker compose' nor 'docker-compose' is available. Please install Docker Compose."
fi

# Step 11: Stop any existing containers and start fresh
info "Stopping existing containers (if any)..."
$DOCKER_COMPOSE_CMD down 2>/dev/null || true

info "Starting Docker Private Registry..."
$DOCKER_COMPOSE_CMD up -d

# Step 12: Wait for container to be ready
info "Waiting for registry container to start..."
sleep 3

# Step 13: Verify container is running
info "Verifying container status..."
if ! $DOCKER_COMPOSE_CMD ps | grep -q "docker-registry"; then
    error_exit "Registry container failed to start! Check logs with: $DOCKER_COMPOSE_CMD logs"
fi

# Step 14: Verify volume mounts inside container
info "Verifying volume mounts inside container..."
if ! docker exec docker-registry test -f /auth/htpasswd; then
    error_exit "htpasswd file NOT accessible inside container! This will cause authentication to fail."
fi

if ! docker exec docker-registry test -f /certs/registry.crt; then
    error_exit "SSL certificate NOT accessible inside container!"
fi

if ! docker exec docker-registry test -f /certs/registry.key; then
    error_exit "SSL key NOT accessible inside container!"
fi

info "✓ All files are accessible inside container"

# Step 15: Display container file verification
info "Container file verification:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Files in /auth/:"
docker exec docker-registry ls -lah /auth/
echo ""
echo "Files in /certs/:"
docker exec docker-registry ls -lah /certs/
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

info "✓ Installation completed successfully!"
info "Registry is now running at https://$REGISTRY_DOMAIN:5000"
echo ""
info "To test your registry from client machine:"
info "  docker login $REGISTRY_DOMAIN:5000"
info "  (Use the username and password you just created)"
echo ""
info "To view logs:"
info "  $DOCKER_COMPOSE_CMD logs -f"
echo ""
info "To verify registry is responding:"
info "  curl -k https://$REGISTRY_DOMAIN:5000/v2/"
