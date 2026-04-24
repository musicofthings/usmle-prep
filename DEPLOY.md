# USMLE AI Exam Prep — Cloudflare Deployment Guide

## Prerequisites
- Cloudflare account (free tier is sufficient to start)
- Node.js 18+ installed locally
- Wrangler CLI: `npm install -g wrangler`
- Authenticate: `wrangler login`

---

## Step 1 — Clone & install

```bash
git clone <your-repo>
cd usmle-cloudflare
npm init -y
npm install wrangler --save-dev
```

---

## Step 2 — Create Cloudflare resources

### KV namespace (question cache)
```bash
wrangler kv:namespace create QUESTION_CACHE
# Copy the output `id` into wrangler.toml → [[kv_namespaces]] id = "..."
```

### D1 database (session storage)
```bash
wrangler d1 create usmle-sessions
# Copy the output `database_id` into wrangler.toml → [[d1_databases]] database_id = "..."

# Apply schema
wrangler d1 execute usmle-sessions --file schema.sql
# Verify tables exist:
wrangler d1 execute usmle-sessions --command "SELECT name FROM sqlite_master WHERE type='table'"
```

### AI Gateway (Anthropic proxy with caching + observability)
1. Cloudflare dashboard → AI → AI Gateway → Create Gateway
2. Name it `usmle-gateway`
3. Copy the gateway URL: `https://gateway.ai.cloudflare.com/v1/{account_id}/usmle-gateway/anthropic`
4. Set as a secret (step 3 below)

---

## Step 3 — Set secrets

```bash
# Required
wrangler secret put ANTHROPIC_API_KEY
# Paste your Anthropic API key when prompted

wrangler secret put ALLOWED_ORIGIN
# Paste your Pages URL, e.g.: https://usmle-prep.pages.dev
# (Use http://localhost:8788 during local dev)

# Recommended
wrangler secret put ANTHROPIC_GATEWAY_URL
# Paste: https://gateway.ai.cloudflare.com/v1/{account_id}/usmle-gateway/anthropic
```

---

## Step 4 — Test locally

```bash
# Start Worker dev server
wrangler dev

# In another terminal, test the question endpoint:
curl -X POST http://localhost:8787/api/question \
  -H "Content-Type: application/json" \
  -d '{"step":"Step 1","subject":"Pharmacology","difficulty":"Medium"}'

# Test health:
curl http://localhost:8787/health
```

---

## Step 5 — Deploy Worker

```bash
wrangler deploy
# Output: https://usmle-question-api.{your-subdomain}.workers.dev
```

---

## Step 6 — Deploy frontend to Cloudflare Pages

### Option A — Drag and drop (fastest)
1. Build/prepare your `frontend/index.html`
2. In `frontend/index.html`, replace `http://localhost:8787` with your Worker URL
3. Go to cloudflare.com/pages → Create project → Direct upload
4. Drag the `frontend/` folder
5. Pages gives you `https://usmle-prep.pages.dev`
6. Update `ALLOWED_ORIGIN` secret to match:
   ```bash
   wrangler secret put ALLOWED_ORIGIN
   # https://usmle-prep.pages.dev
   ```

### Option B — GitHub CI/CD (recommended for production)
```bash
# Connect your GitHub repo to Cloudflare Pages
# Build command: (none — static HTML)
# Output directory: frontend/
# Pages auto-deploys on every push to main
```

---

## Step 7 — Enable AI Gateway features

In Cloudflare dashboard → AI → AI Gateway → `usmle-gateway`:

| Feature | Setting | Benefit |
|---------|---------|---------|
| Prompt caching | TTL: 1 hour | Identical prompts served instantly, reduces API cost ~30% |
| Rate limiting | 100 req/min per IP | Protects against abuse at the gateway layer |
| Log streaming | Enabled | Full visibility into every Claude request/response |
| Analytics | Auto | Track token usage, cost, latency by model |
| Fallback model | claude-haiku-4-5 | Auto-fallback if Sonnet hits rate limits |

---

## Step 8 — Monitor & scale

### View KV cache stats
```bash
wrangler kv:key list --namespace-id <your-kv-id> | grep "^pool:"
```

### Query D1 analytics
```bash
# Overall stats by Step
wrangler d1 execute usmle-sessions --command "SELECT * FROM v_step_stats"

# Hardest subjects (lowest % correct)
wrangler d1 execute usmle-sessions --command "SELECT * FROM v_subject_stats ORDER BY pct_correct ASC LIMIT 10"

# Recent sessions
wrangler d1 execute usmle-sessions --command "SELECT * FROM sessions ORDER BY created_at DESC LIMIT 20"
```

---

## Architecture summary

```
Browser
  ↓ HTTPS
Cloudflare Pages          ← static frontend (React/HTML)
  ↓ fetch /api/*
Cloudflare Workers        ← rate limiting, routing, session storage
  ├── KV Store            ← 35% cache hit rate on question pool (7-day TTL)
  ├── D1 Database         ← sessions, subject breakdown, aggregate analytics
  └── AI Gateway          ← prompt caching, rate limits, cost observability
        ↓ proxied
Anthropic Claude Sonnet   ← question generation
```

## Cost estimates (free tier covers ~10k questions/month)

| Resource | Free tier | ~10k q/month |
|----------|-----------|--------------|
| Workers | 100k req/day | ✅ Free |
| KV reads | 100k/day | ✅ Free |
| KV writes | 1k/day | ✅ Free |
| D1 reads | 5M rows/day | ✅ Free |
| D1 writes | 100k/day | ✅ Free |
| Pages | Unlimited | ✅ Free |
| Anthropic | Pay-per-token | ~$2-5/month |

---

## Environment variables reference

| Secret | Required | Description |
|--------|----------|-------------|
| `ANTHROPIC_API_KEY` | ✅ Yes | Anthropic API key |
| `ALLOWED_ORIGIN` | ✅ Yes | CORS allowed origin (your Pages URL) |
| `ANTHROPIC_GATEWAY_URL` | Recommended | AI Gateway base URL for Anthropic |
