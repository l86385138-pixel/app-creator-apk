#!/usr/bin/env bash
set -euo pipefail
: "${SUPABASE_URL:?SUPABASE_URL secret is required}"
: "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY secret is required}"
api="$SUPABASE_URL/rest/v1"; headers=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" -H 'Content-Type: application/json' -H 'Prefer: return=representation')
row='[]'; BUILD_ID=''; PROJECT_ID=''
fail_build(){ rc=$?; if [ -n "${BUILD_ID:-}"