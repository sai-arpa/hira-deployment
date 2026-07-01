#!/bin/bash
# =============================================================================
# GlobalData SQL Script Runner
# Usage: ./run-globaldata.sh
# =============================================================================

set -e  # Exit on any error

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Setup logging
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/globaldata-$TIMESTAMP.log"

# Tee all output to log file and terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1"; }
# =============================================================================

log "=========================================="
log "  GLOBALDATA SQL RUNNER STARTED"
log "  Log: $LOG_FILE"
log "=========================================="

# --- Step 1: Start SSH Agent ---
log "Setting up SSH agent..."
eval "$(ssh-agent -s)" > /dev/null
ssh-add "$SSH_KEY" 2>/dev/null
log_success "SSH agent ready"

# --- Step 2: Clone globaldata repo ---
log "Cloning globaldata repo (branch: $BRANCH_GLOBALDATA)..."
rm -rf "$CLONE_DIR/globaldata"
mkdir -p "$CLONE_DIR/globaldata"
git clone --branch "$BRANCH_GLOBALDATA" --single-branch "$GIT_GLOBALDATA" "$CLONE_DIR/globaldata"
log_success "Repo cloned"

# --- Step 3: Verify SQL file exists ---
SQL_FILE="$CLONE_DIR/globaldata/$GLOBALDATA_SQL"
if [ ! -f "$SQL_FILE" ]; then
    log_error "SQL file not found at: $SQL_FILE"
    exit 1
fi
log_success "SQL file found: $GLOBALDATA_SQL"

# --- Step 4: Copy SQL to /tmp (postgres user needs access) ---
log "Preparing SQL file..."
cp "$SQL_FILE" /tmp/globaldata_run.sql
chmod 644 /tmp/globaldata_run.sql
log_success "SQL file ready"

# --- Step 5: Run SQL script ---
log "Running SQL script against database: $DB_NAME..."
sudo -u "$DB_USER" psql -d "$DB_NAME" -f /tmp/globaldata_run.sql
log_success "SQL script executed successfully"

# --- Step 6: Cleanup ---
log "Cleaning up..."
rm -f /tmp/globaldata_run.sql
rm -rf "$CLONE_DIR/globaldata"
log_success "Cleanup done"

# --- Kill SSH agent ---
ssh-agent -k > /dev/null 2>&1

log "=========================================="
log_success "GLOBALDATA SQL RUNNER COMPLETED"
log "  Log saved to: $LOG_FILE"
log "=========================================="
