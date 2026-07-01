#!/bin/bash
# =============================================================================
# Backend Deployment Script
# Usage: ./deploy-backend.sh
# =============================================================================

set -e
# Prevent concurrent deployments
LOCK_FILE="/tmp/backend-deploy.lock"

exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "Another deployment is already running"
    echo "If no deployment is running, remove the lock with: rm $LOCK_FILE"
    exit 1
}

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Setup logging
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/backend-$TIMESTAMP.log"
MIGRATION_LOG="$LOG_DIR/migration-$TIMESTAMP.txt"
DEPLOYMENT_HISTORY_DIR="/opt/deployment/deployment-history"

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
log()         { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1"; }
log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1"; }
# =============================================================================

# --- Rollback Function ---
rollback() {
    local BACKUP_DIR="$DEPLOY_BACKEND/../backend_backup_$TIMESTAMP"
    log_error "Initiating rollback..."
    if [ -d "$BACKUP_DIR" ]; then
        log_error "Restoring previous deployment from backup..."
        sudo rsync -av --delete \
            --exclude='.env' \
            --exclude='wwwroot/' \
            "$BACKUP_DIR/" "$DEPLOY_BACKEND/"
        log "Setting deployment ownership..."
        sudo chown -R www-data:www-data "$DEPLOY_BACKEND"
        log_success "Ownership changed to www-data"
        sudo systemctl restart "$BACKEND_SERVICE"
        sleep 10
        log_success "Rollback complete — previous binary restored"
    else
        log_error "No backup found — cannot rollback automatically"
        log_error "Manual intervention required"
    fi
}

# --- Cleanup trap (always runs on exit) ---
trap 'log "Cleaning up..."; rm -rf "$CLONE_DIR/backend"; ssh-agent -k > /dev/null 2>&1; log "Cleanup done"' EXIT

log "=========================================="
log "  BACKEND DEPLOYMENT STARTED"
log "  Log:            $LOG_FILE"
log "  Migration log:  $MIGRATION_LOG"
log "=========================================="

# --- Step 1: SSH Agent ---
log "Setting up SSH agent..."
eval "$(ssh-agent -s)" > /dev/null
ssh-add "$SSH_KEY" || { log_error "Failed to load SSH key: $SSH_KEY"; exit 1; }
log_success "SSH agent ready"

# --- Step 2: Clone repo ---
log "Cloning backend repo (branch: $BRANCH_BACKEND)..."
rm -rf "$CLONE_DIR/backend"
mkdir -p "$CLONE_DIR/backend"
git clone --branch "$BRANCH_BACKEND" --single-branch "$GIT_BACKEND" "$CLONE_DIR/backend"
log_success "Repo cloned"

DEPLOY_COMMIT=$(git -C "$CLONE_DIR/backend" rev-parse HEAD)
DEPLOY_DATE=$(date '+%Y-%m-%d %H:%M:%S %Z')

# --- Step 2.5: Pin .NET 8 SDK ---
log "Pinning .NET SDK to version 8..."
echo '{"sdk":{"version":"8.0.0","rollForward":"latestMinor"}}' > "$CLONE_DIR/backend/global.json"
log_success "SDK pinned to .NET 8"

# --- Step 3: Build and publish ---
log "Building and publishing .NET app..."
cd "$CLONE_DIR/backend/Api"
dotnet publish -c Release -o publish
log_success "Build successful"

# --- Step 3.5: Backup current deployment ---
log "Backing up current deployment..."
BACKUP_DIR="$DEPLOY_BACKEND/../backend_backup_$TIMESTAMP"
if [ -d "$DEPLOY_BACKEND" ]; then
    sudo rsync -av \
       --exclude='wwwroot/' \
       --exclude='.env' \
       "$DEPLOY_BACKEND/" "$BACKUP_DIR/"
    log_success "Backup saved to: $BACKUP_DIR"
else
    log "No existing deployment found — skipping backup"
fi

# --- Step 4: Deploy files ---
log "Deploying to $DEPLOY_BACKEND..."
sudo mkdir -p "$DEPLOY_BACKEND"
sudo rsync -av --delete \
    --exclude='.env' \
    --exclude='wwwroot/' \
    "$CLONE_DIR/backend/Api/publish/" "$DEPLOY_BACKEND/"
log_success "Files deployed"
log "Setting deployment ownership..."
sudo chown -R www-data:www-data "$DEPLOY_BACKEND"
log_success "Deployment ownership updated to www-data"

# --- Step 5: Copy .env ---
log "Copying backend .env..."
sudo cp "$SCRIPT_DIR/.env.backend" "$DEPLOY_BACKEND/.env"
sudo chown www-data:www-data "$DEPLOY_BACKEND/.env"
sudo chmod 600 "$DEPLOY_BACKEND/.env"
log_success ".env copied"

# --- Step 6: Restart service ---
log "Restarting $BACKEND_SERVICE..."
sudo systemctl restart "$BACKEND_SERVICE"
log "Waiting 20 seconds for app to start and migrations to run..."
sleep 20

# --- Step 7: Service status check ---
log "Checking service status..."

set +e
SERVICE_STATUS=$(sudo systemctl is-active "$BACKEND_SERVICE")
SERVICE_CHECK_FAILED=false

if [ "$SERVICE_STATUS" != "active" ]; then
    SERVICE_CHECK_FAILED=true
    log_error "Service is not active (status: $SERVICE_STATUS)"
    log_error "Last 30 lines of service logs:"
    sudo journalctl -u "$BACKEND_SERVICE" -n 30 --no-pager
else
    log_success "Service is active"
fi
set -e

# --- Step 8: Migration Verifier ---
log "Running migration verifier..."

set +e
MIGRATION_CHECK=$(sudo -u www-data dotnet "$DEPLOY_BACKEND/eProcurement.MigrationVerifier.dll" 2>&1)
MIGRATION_EXIT=$?
set -e

echo "$MIGRATION_CHECK" > "$MIGRATION_LOG"
log "Migration verifier output saved to: $MIGRATION_LOG"

MIGRATION_CHECK_FAILED=false

if [ $MIGRATION_EXIT -ne 0 ]; then
    MIGRATION_CHECK_FAILED=true

    log_error "Migration verification failed:"
    echo "$MIGRATION_CHECK" | while IFS= read -r line; do
        log_error "  $line"
    done
else
    log_success "All migrations applied successfully"
fi

# --- Step 9: API Health Check ---
log "Checking API health..."

set +e
HTTP_RESPONSE=$(curl -s http://localhost:5000/api/config/portal-setting)
HTTP_SUCCESS=$(echo "$HTTP_RESPONSE" | grep -o '"success":true')
set -e

API_CHECK_FAILED=false

if [ -z "$HTTP_SUCCESS" ]; then
    API_CHECK_FAILED=true

    log_error "API health check failed. Response: $HTTP_RESPONSE"
    sudo journalctl -u "$BACKEND_SERVICE" -n 30 --no-pager
else
    log_success "API health check passed"
fi

# --- Step 10: Final Deployment Validation ---
if [ "$SERVICE_CHECK_FAILED" = true ] || \
   [ "$MIGRATION_CHECK_FAILED" = true ] || \
   [ "$API_CHECK_FAILED" = true ]; then

    log_error "Deployment validation failed"

    [ "$SERVICE_CHECK_FAILED" = true ] && log_error " - Service check failed"
    [ "$MIGRATION_CHECK_FAILED" = true ] && log_error " - Migration verification failed"
    [ "$API_CHECK_FAILED" = true ] && log_error " - API health check failed"

    rollback
    exit 1
fi

log_success "All deployment validations passed"

# --- Cleanup old backups (keep last 3) ---
log "Cleaning old backups..."
ls -dt "$DEPLOY_BACKEND/../backend_backup_"* 2>/dev/null | tail -n +4 | xargs sudo rm -rf 2>/dev/null || true
log_success "Old backups cleaned"

log "=========================================="
log_success "BACKEND DEPLOYMENT COMPLETED"
log "  Log saved to:       $LOG_FILE"
log "  Migration log:      $MIGRATION_LOG"
log "=========================================="
