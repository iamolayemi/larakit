#!/usr/bin/env bash
# =============================================================================
#  Configuration
#  Set these values before pushing to GitHub, or pass them as env vars.
# =============================================================================

LARAKIT_VERSION="${LARAKIT_VERSION:-1.0.0}"

GITHUB_USER="${GITHUB_USER:-iamolayemi}"
GITHUB_REPO="${GITHUB_REPO:-larakit}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

SETUP_BASE_URL="${SETUP_BASE_URL:-https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}}"

# CREDS_FILE: overridden by LARAKIT_APP in creds.sh if set
CREDS_FILE="${CREDS_FILE:-$HOME/.larakit-creds}"

# Timeout for remote downloads (seconds)
LARAKIT_CURL_TIMEOUT="${LARAKIT_CURL_TIMEOUT:-30}"

export LARAKIT_VERSION GITHUB_USER GITHUB_REPO GITHUB_BRANCH SETUP_BASE_URL CREDS_FILE LARAKIT_CURL_TIMEOUT
