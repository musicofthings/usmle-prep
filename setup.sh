#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  USMLE AI Exam Prep — One-command Cloudflare setup
#  Usage: ./setup.sh
#  Needs: Node.js 18+, a Cloudflare account, an Anthropic API key
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

step() { echo -e "\n${BOLD}${BLUE}━━ $1${NC}"; }
ok()   { echo -e "   ${GREEN}✓${NC}  $1"; }
info() { echo -e "   ${CYAN}ℹ${NC}  $1"; }
warn() { echo -e "   ${YELLOW}⚠${NC}  $1"; }
die()  { echo -e "   ${RED}✗${NC}  $1"; exit 1; }

# macOS vs Linux sed
if [[ "${OSTYPE:-}" == "darwin"* ]]; then
  sedi() { sed -i '' "$@"; }
else
  sedi() { sed -i "$@"; }
fi

# ── Banner ─────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║   USMLE AI Exam Prep · Cloudflare Setup     ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
echo ""
info "This script will set up everything in ~3 minutes:"
echo "     1. Install Wrangler CLI (if needed)"
echo "     2. Log you into Cloudflare"
echo "     3. Create KV namespace for question caching"
echo "     4. Create D1 database for session analytics"
echo "     5. Apply the database schema"
echo "     6. Set your Anthropic API key as a secret"
echo "     7. Deploy the Cloudflare Worker"
echo "     8. Deploy the frontend to Cloudflare Pages"
echo ""
echo -e "  ${YELLOW}You will need:${NC} Anthropic API key (from console.anthropic.com)"
echo ""
read -rp "  Press Enter to start (Ctrl+C to cancel)..."

# ── Prerequisites ──────────────────────────────────────────────────────────
step "Checking prerequisites"

command -v node &>/dev/null || die "Node.js not found. Install from https://nodejs.org (v18+)"
NODE_VER=$(node -e "process.stdout.write(String(process.version.match(/^v(\d+)/)[1]))")
[ "$NODE_VER" -ge 18 ] || die "Node.js 18+ required (found $(node --version))"
ok "Node.js $(node --version)"

if ! command -v wrangler &>/dev/null; then
  info "Installing Wrangler CLI..."
  npm install -g wrangler@latest --quiet
fi
ok "Wrangler $(wrangler --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

# ── Cloudflare login ───────────────────────────────────────────────────────
step "Logging into Cloudflare"
info "A browser window will open — log in and click 'Allow'."
wrangler login
ok "Authenticated with Cloudflare"

# ── KV namespace ───────────────────────────────────────────────────────────
step "Creating KV namespace (question cache pool)"

KV_RAW=$(wrangler kv:namespace create QUESTION_CACHE 2>&1 || true)

if echo "$KV_RAW" | grep -qi "already exists"; then
  warn "Namespace already exists — fetching existing ID..."
  KV_LIST=$(wrangler kv:namespace list 2>/dev/null || echo "[]")
  KV_ID=$(echo "$KV_LIST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ns=[x for x in d if 'QUESTION_CACHE' in x.get('title','')]
print(ns[0]['id'] if ns else '')
" 2>/dev/null || echo "")
else
  # parse from output (handles various wrangler output formats)
  KV_ID=$(echo "$KV_RAW" | grep -oE '"id": "[a-f0-9]{32}"' | head -1 | grep -oE '[a-f0-9]{32}' || \
          echo "$KV_RAW" | grep -oE 'id: [a-f0-9]{32}' | head -1 | awk '{print $2}' || echo "")
fi

if [ -z "$KV_ID" ]; then
  echo "$KV_RAW"
  warn "Could not parse KV ID automatically."
  read -rp "  Paste the KV namespace ID from output above: " KV_ID
fi

# Only replace placeholder if it's still there
grep -q "REPLACE_WITH_YOUR_KV_NAMESPACE_ID" wrangler.toml 2>/dev/null && \
  sedi "s/REPLACE_WITH_YOUR_KV_NAMESPACE_ID/$KV_ID/" wrangler.toml
ok "KV namespace: $KV_ID"

# ── D1 database ────────────────────────────────────────────────────────────
step "Creating D1 database (session analytics)"

D1_RAW=$(wrangler d1 create usmle-sessions 2>&1 || true)

if echo "$D1_RAW" | grep -qi "already exists"; then
  warn "Database already exists — fetching existing ID..."
  D1_LIST=$(wrangler d1 list 2>/dev/null || echo "")
  D1_ID=$(echo "$D1_LIST" | grep -A3 "usmle-sessions" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1 || echo "")
else
  D1_ID=$(echo "$D1_RAW" | grep "database_id" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -1 || echo "")
fi

if [ -z "$D1_ID" ]; then
  echo "$D1_RAW"
  warn "Could not parse D1 ID automatically."
  read -rp "  Paste the database_id from output above: " D1_ID
fi

grep -q "REPLACE_WITH_YOUR_D1_DATABASE_ID" wrangler.toml 2>/dev/null && \
  sedi "s/REPLACE_WITH_YOUR_D1_DATABASE_ID/$D1_ID/" wrangler.toml
ok "D1 database: $D1_ID"

# ── Apply schema ───────────────────────────────────────────────────────────
step "Applying database schema"
wrangler d1 execute usmle-sessions --file schema.sql --remote 2>&1 | grep -v "^$" | tail -5
ok "Tables and views created"

# ── API key secret ─────────────────────────────────────────────────────────
step "Setting Anthropic API key"
echo ""
info "Get your key at: https://console.anthropic.com/settings/keys"
echo ""
read -rp "  Anthropic API key (sk-ant-...): " -s ANTHROPIC_KEY
echo ""
[ -z "$ANTHROPIC_KEY" ] && die "API key cannot be empty."
printf '%s' "$ANTHROPIC_KEY" | wrangler secret put ANTHROPIC_API_KEY
ok "ANTHROPIC_API_KEY saved"

# Temporary wildcard — tightened after Pages deploy
printf '*' | wrangler secret put ALLOWED_ORIGIN
ok "ALLOWED_ORIGIN set (will update after Pages deploy)"

# ── Deploy Worker ──────────────────────────────────────────────────────────
step "Deploying Cloudflare Worker"
DEPLOY_OUT=$(wrangler deploy 2>&1)
echo "$DEPLOY_OUT" | grep -E '(Uploaded|Deployed|workers\.dev)' || echo "$DEPLOY_OUT" | tail -4

WORKER_URL=$(echo "$DEPLOY_OUT" | grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' | head -1 || echo "")
if [ -z "$WORKER_URL" ]; then
  warn "Could not detect Worker URL."
  read -rp "  Paste your Worker URL (https://...workers.dev): " WORKER_URL
fi
ok "Worker: $WORKER_URL"

# ── Update frontend ────────────────────────────────────────────────────────
step "Updating frontend with Worker URL"
sedi "s|https://usmle-question-api.YOUR_SUBDOMAIN.workers.dev|$WORKER_URL|g" frontend/index.html
ok "API_BASE updated in frontend/index.html"

# ── Deploy Pages ───────────────────────────────────────────────────────────
step "Deploying frontend to Cloudflare Pages"
PAGES_OUT=$(wrangler pages deploy frontend --project-name=usmle-prep --commit-dirty=true 2>&1)
echo "$PAGES_OUT" | grep -E '(Deploying|Success|pages\.dev)' || echo "$PAGES_OUT" | tail -4

PAGES_URL=$(echo "$PAGES_OUT" | grep -oE 'https://[a-zA-Z0-9._-]+\.pages\.dev' | head -1 || echo "https://usmle-prep.pages.dev")
ok "Pages: $PAGES_URL"

# Tighten CORS to actual Pages URL
printf '%s' "$PAGES_URL" | wrangler secret put ALLOWED_ORIGIN
ok "ALLOWED_ORIGIN updated to $PAGES_URL"

# ── AI Gateway instructions ────────────────────────────────────────────────
step "Optional: Enable AI Gateway (adds caching + analytics)"
echo ""
echo -e "  ${CYAN}1.${NC}  dash.cloudflare.com → AI → AI Gateway → Create Gateway"
echo -e "  ${CYAN}2.${NC}  Name it: ${BOLD}usmle-gateway${NC}"
echo -e "  ${CYAN}3.${NC}  Copy the URL and run:"
echo ""
echo -e "       ${BOLD}wrangler secret put ANTHROPIC_GATEWAY_URL${NC}"
echo ""
echo -e "  ${CYAN}4.${NC}  Paste:  https://gateway.ai.cloudflare.com/v1/ACCOUNT/usmle-gateway/anthropic"
echo ""

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║         Deployment complete! 🎉          ║${NC}"
echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Frontend :${NC}  $PAGES_URL"
echo -e "  ${BOLD}Worker   :${NC}  $WORKER_URL"
echo -e "  ${BOLD}Health   :${NC}  $WORKER_URL/health"
echo ""
info "Quick test:"
echo "  curl -s $WORKER_URL/health | python3 -m json.tool"
echo ""
info "View analytics:"
echo "  wrangler d1 execute usmle-sessions --command \"SELECT * FROM v_step_stats\" --remote"
echo ""
