#!/bin/bash
# =============================================================================
# Central Configuration
# Edit this file to change deployment settings
# =============================================================================

# --- SSH / Git ---
SSH_KEY="$HOME/.ssh/keys/github-pem"
GIT_BACKEND="git@github.com:Force-Intellect/eProcurement.git"
GIT_FRONTEND="git@github.com:Force-Intellect/e-procurement-user-interface.git"
GIT_GLOBALDATA="git@github.com:Force-Intellect/eProcurementDatabase.git"

BRANCH_BACKEND="Develop"
BRANCH_FRONTEND="staging"
BRANCH_GLOBALDATA="Develop"

# --- Deployment Paths ---
DEPLOY_BACKEND="/var/www/eProcurement/backend"
DEPLOY_FRONTEND="/var/www/eProcurement/frontend"

# --- Service Names ---
BACKEND_SERVICE="eProcurementapi.service"

# --- Temp Clone Directory ---
CLONE_DIR="/tmp/deployment"

# --- Logs Directory ---
LOG_DIR="/opt/deployment/logs"

# --- GlobalData SQL file path inside repo ---
GLOBALDATA_SQL="SqlQueries/GlobalData.sql"

# --- Database (for globaldata script) ---
DB_NAME="eProcurement_Reals_Staging_1"
DB_USER="postgres"
