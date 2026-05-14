#!/bin/bash
set -e

echo "🔍 Scanner — AI Model Safety Scanner"
echo "======================================"
echo ""

# Check prerequisites
for cmd in docker openssl curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ $cmd is required but not installed."
    exit 1
  fi
done

if ! docker compose version &>/dev/null; then
  echo "❌ docker compose (v2) is required."
  exit 1
fi

# Create directory
INSTALL_DIR="${1:-scanner}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "📁 Installing to $(pwd)"

# Pre-create storage directory owned by the current user.
# The container entrypoint will fix ownership if needed, but this avoids
# Docker creating it as root:root on first compose-up.
mkdir -p storage

# Download compose file
echo "⬇️  Downloading docker-compose.yml..."
curl -sfL "https://raw.githubusercontent.com/0din-ai/ai-scanner/main/dist/docker-compose.yml" -o docker-compose.yml

# Generate secrets
SECRET_KEY_BASE=$(openssl rand -hex 64)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
ADMIN_INITIAL_PASSWORD=$(openssl rand -base64 24)

# Write .env
cat > .env <<EOF
SECRET_KEY_BASE=$SECRET_KEY_BASE
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
ADMIN_INITIAL_PASSWORD=$ADMIN_INITIAL_PASSWORD
EOF

echo "🔐 Generated secrets in .env"

# Start
echo "🚀 Starting Scanner..."
docker compose up -d

# Wait for health
echo "⏳ Waiting for Scanner to be ready..."
for i in $(seq 1 30); do
  if curl -sf http://localhost/up > /dev/null 2>&1; then
    echo ""
    echo "✅ Scanner is ready!"
    echo ""
    echo "   URL:      http://localhost"
    echo "   Email:    admin@example.com"
    echo "   Password: $ADMIN_INITIAL_PASSWORD"
    echo ""
    echo "   ⚠️  Store this generated password securely and change it after first login."
    echo ""
    echo "   To stop:  cd $(pwd) && docker compose down"
    echo "   To start: cd $(pwd) && docker compose up -d"
    exit 0
  fi
  printf "."
  sleep 5
done

echo ""
echo "⏳ Scanner is still starting up. Check with:"
echo "   cd $(pwd) && docker compose logs -f scanner"
