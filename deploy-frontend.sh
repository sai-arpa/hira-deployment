#!/bin/bash
# =============================================================================
# Frontend Deployment Script
# Usage: ./deploy-frontend.sh
# =============================================================================

set -e  # Exit on any error

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Setup logging
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/frontend-$TIMESTAMP.log"

# Tee all output to log file and terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1"; }
# =============================================================================

trap 'log "Cleaning up..."; rm -rf "$CLONE_DIR/frontend"; ssh-agent -k > /dev/null 2>&1; log "Cleanup done"' EXIT

log "=========================================="
log "  FRONTEND DEPLOYMENT STARTED"
log "  Log: $LOG_FILE"
log "=========================================="

# --- Step 1: Start SSH Agent ---
log "Setting up SSH agent..."
eval "$(ssh-agent -s)" > /dev/null
ssh-add "$SSH_KEY" || { log_error "Failed to load SSH key: $SSH_KEY"; exit 1; }
log_success "SSH agent ready"

# --- Step 2: Clean and clone repo ---
log "Cloning frontend repo (branch: $BRANCH_FRONTEND)..."
rm -rf "$CLONE_DIR/frontend"
mkdir -p "$CLONE_DIR/frontend"
git clone --branch "$BRANCH_FRONTEND" --single-branch "$GIT_FRONTEND" "$CLONE_DIR/frontend"
log_success "Repo cloned"

# --- Step 3: Copy .env before build ---
log "Copying frontend .env..."
cp "$SCRIPT_DIR/.env.frontend" "$CLONE_DIR/frontend/.env"
log_success ".env copied"

# --- Step 4: Install dependencies ---
log "Installing npm dependencies..."
cd "$CLONE_DIR/frontend"
npm ci --prefer-offline 2>/dev/null || npm install
log_success "Dependencies installed"

# --- Step 5: Build ---
log "Building React app..."
export NODE_OPTIONS="--max-old-space-size=4096"
npm run build
log_success "Build successful"

# --- Step 6: Deploy to target directory ---
log "Deploying to $DEPLOY_FRONTEND..."
sudo mkdir -p "$DEPLOY_FRONTEND"
sudo rsync -av --delete "$CLONE_DIR/frontend/dist/" "$DEPLOY_FRONTEND/"
log_success "Files deployed"

# --- Step 7: Fix permissions for nginx ---
log "Setting permissions..."
sudo chown -R www-data:www-data "$DEPLOY_FRONTEND"
sudo chmod -R 755 "$DEPLOY_FRONTEND"
log_success "Permissions set"

# --- Step 8: Reload nginx ---
log "Reloading nginx..."
sudo nginx -t
sudo systemctl reload nginx
log_success "Nginx reloaded"


log "=========================================="
log_success "FRONTEND DEPLOYMENT COMPLETED"
log "  Log saved to: $LOG_FILE"
log "=========================================="
