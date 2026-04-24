/**
 * USMLE AI Exam Prep · Cloudflare Worker
 *
 * API key resolution order:
 *   1. User-provided key in request body (BYOK — user's own Anthropic key)
 *   2. ANTHROPIC_API_KEY env secret (set in CF dashboard — shared/free tier)
 *   3. Neither present → 401, frontend prompts user to enter their key
 *
 * Endpoints:
 *   GET  /api/config    — tells frontend if a server key exists
 *   POST /api/question  — generate question (rate-limited, cacheable)
 *   POST /api/session   — save session results to D1
 *   GET  /api/stats     — aggregate stats from D1
 *   GET  /health        — health + config check
 */

const MODEL      = "claude-sonnet-4-20250514";
const RATE_LIMIT = 60;
const CACHE_TTL  = 604800;
const CACHE_PROB = 0.35;
const MAX_POOL   = 25;

const STEPS = {
  "Step 1":    ["Biochemistry","Molecular Biology","Microbiology","Immunology",
                "Pathology","Pharmacology","Anatomy","Physiology","Behavioral Science","Genetics"],
  "Step 2 CK": ["Internal Medicine","Surgery","OB/GYN","Pediatrics","Psychiatry",
                "Neurology","Emergency Medicine","Preventive Medicine","Dermatology","Rheumatology"],
  "Step 3":    ["Ambulatory Medicine","Inpatient Management","Emergency Medicine",
                "Biostatistics & Epi","Patient Safety","Geriatrics","Women's Health","Pharmacotherapy"],
};

function buildPrompt(step, subject, difficulty) {
  const sInstr = {
    "Step 1":    `USMLE Step 1 on ${subject}. Vignette 60-100 words. Test pathophysiology mechanisms, biochemical pathways, pharmacology mechanisms/side effects, or anatomical correlations. Require multi-step reasoning.`,
    "Step 2 CK": `USMLE Step 2 CK on ${subject}. Clinical vignette 130-200 words with age, sex, chief complaint, history, vitals, exam, labs/imaging. Test diagnosis, next best step, or management.`,
    "Step 3":    `USMLE Step 3 on ${subject}. Complex clinical scenario: outpatient, inpatient, emergency, biostatistics, quality improvement, or patient safety. Multiple data points. Test clinical judgment.`,
  }[step];
  const dInstr = {
    "Easy":  "Classic presentation, single-step reasoning.",
    "Medium":"2-3 concept synthesis, moderate complexity.",
    "Hard":  "Multi-step reasoning, subtle distinctions, tests exceptions.",
    "Mixed": "Choose naturally appropriate difficulty.",
  }[difficulty];
  return `${sInstr}\nDifficulty: ${difficulty} — ${dInstr}\n\nRules:\n- 5 choices A-E, exactly ONE correct\n- All distractors genuinely plausible\n- No "All/None of the above"\n- Explanation 150-250 words: why correct is right + why each distractor is wrong\n- keyPoint: single sentence, core concept\n\nReturn ONLY valid JSON, no markdown:\n{"stem":"...","options":{"A":"...","B":"...","C":"...","D":"...","E":"..."},"correct":"B","explanation":"...","keyPoint":"...","subject":"${subject}","qType":"Diagnosis|NextStep|Management|Mechanism|Pharmacology|Anatomy|Biostats|Ethics|Other"}`;
}

function corsHeaders(origin, allowedOrigin) {
  const allow = (!allowedOrigin || allowedOrigin === "*" ||
    origin === allowedOrigin || origin.startsWith("http://localhost"))
    ? (origin || "*") : allowedOrigin;
  return {
    "Access-Control-Allow-Origin":  allow,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age":       "86400",
  };
}

async function checkRateLimit(ip, kv) {
  const key = `rl:${ip}:${Math.floor(Date.now() / 3_600_000)}`;
  try {
    const count = parseInt(await kv.get(key) || "0", 10);
    if (count >= RATE_LIMIT) return false;
    await kv.put(key, String(count + 1), { expirationTtl: 3600 });
    return true;
  } catch { return true; }
}

function validateApiKey(key) {
  return typeof key === "string" && key.startsWith("sk-ant-") && key.length > 30;
}

async function callClaude(prompt, apiKey, env) {
  const base = env.ANTHROPIC_GATEWAY_URL ?? "https://api.anthropic.com";
  const headers = {
    "Content-Type": "application/json",
    "x-api-key": apiKey,
    "anthropic-version": "2023-06-01",
  };
  if (env.ANTHROPIC_GATEWAY_URL) {
    headers["cf-aig-cache-ttl"]  = "3600";
    headers["cf-aig-skip-cache"] = "false";
  }
  const res = await fetch(`${base}/v1/messages`, {
    method: "POST", headers,
    body: JSON.stringify({
      model: MODEL, max_tokens: 1000,
      system: "You are an expert USMLE question author. Return ONLY valid JSON. No markdown fences. No text outside the JSON object.",
      messages: [{ role: "user", content: prompt }],
    }),
  });
  if (!res.ok) throw new Error(`Anthropic:${res.status}`);
  const data = await res.json();
  const text = data.content?.find(c => c.type === "text")?.text ?? "";
  return JSON.parse(text.replace(/```(?:json)?\n?|\n?```/g, "").trim());
}

const poolKey = (step, subject, diff) =>
  `pool:${step}:${subject}:${diff}`.replace(/\s+/g, "_");

async function getFromPool(kv, key) {
  try {
    const raw = await kv.get(key);
    if (!raw) return null;
    const pool = JSON.parse(raw);
    return pool.length ? pool[Math.floor(Math.random() * pool.length)] : null;
  } catch { return null; }
}

async function addToPool(kv, key, q) {
  try {
    const raw = await kv.get(key);
    const pool = raw ? JSON.parse(raw) : [];
    if (pool.length >= MAX_POOL) pool.splice(0, 5);
    pool.push(q);
    await kv.put(key, JSON.stringify(pool), { expirationTtl: CACHE_TTL });
  } catch { /* non-critical */ }
}

async function handleConfig(request, env, cors) {
  return Response.json({
    hasServerKey:    !!env.ANTHROPIC_API_KEY,
    requiresUserKey: !env.ANTHROPIC_API_KEY,
    version:         "1.0.0",
  }, { headers: cors });
}

async function handleQuestion(request, env, ctx, cors) {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!await checkRateLimit(ip, env.QUESTION_CACHE)) {
    return Response.json({ error: "Rate limit reached — 60 questions/hour per IP." },
      { status: 429, headers: cors });
  }

  let step, subject, difficulty, userApiKey;
  try {
    ({ step, subject, difficulty, apiKey: userApiKey } = await request.json());
    if (!STEPS[step]) throw new Error("invalid step");
  } catch {
    return Response.json({ error: "Invalid request body." }, { status: 400, headers: cors });
  }

  // Key resolution
  let apiKey;
  if (userApiKey) {
    if (!validateApiKey(userApiKey)) {
      return Response.json({ error: "invalid_key_format", message: "API key must start with sk-ant-" },
        { status: 400, headers: cors });
    }
    apiKey = userApiKey;
  } else if (env.ANTHROPIC_API_KEY) {
    apiKey = env.ANTHROPIC_API_KEY;
  } else {
    return Response.json({ error: "no_key",
      message: "No API key available. Please add your Anthropic API key in settings." },
      { status: 401, headers: cors });
  }

  const isServerKey = apiKey === env.ANTHROPIC_API_KEY;
  const cKey = poolKey(step, subject, difficulty);

  if (isServerKey && Math.random() < CACHE_PROB) {
    const cached = await getFromPool(env.QUESTION_CACHE, cKey);
    if (cached) return Response.json({ ...cached, _cached: true }, { headers: cors });
  }

  let question;
  try {
    question = await callClaude(buildPrompt(step, subject, difficulty), apiKey, env);
  } catch (err) {
    const msg = String(err.message);
    if (isServerKey) {
      const fallback = await getFromPool(env.QUESTION_CACHE, cKey);
      if (fallback) return Response.json({ ...fallback, _cached: true, _fallback: true }, { headers: cors });
    }
    if (msg.includes("401") || msg.includes("403")) {
      return Response.json({ error: "invalid_key",
        message: "API key rejected by Anthropic. Please check your key." },
        { status: 401, headers: cors });
    }
    return Response.json({ error: "Generation failed. Please retry." }, { status: 502, headers: cors });
  }

  if (isServerKey) ctx.waitUntil(addToPool(env.QUESTION_CACHE, cKey, question));
  return Response.json(question, { headers: cors });
}

async function handleSession(request, env, cors) {
  let body;
  try { body = await request.json(); }
  catch { return Response.json({ error: "Invalid JSON." }, { status: 400, headers: cors }); }

  const { step, difficulty, score, total, avgTime, breakdown } = body;
  if (!step || score == null || !total) {
    return Response.json({ error: "Missing required fields." }, { status: 400, headers: cors });
  }
  const sessionId = crypto.randomUUID();
  const now = new Date().toISOString();
  try {
    await env.DB.prepare(
      "INSERT INTO sessions (id,step,difficulty,score,total,avg_time_s,created_at) VALUES (?,?,?,?,?,?,?)"
    ).bind(sessionId, step, difficulty ?? "Mixed", score, total, avgTime ?? null, now).run();

    if (breakdown) {
      const stmts = Object.entries(breakdown).flatMap(([subject, stats]) =>
        Array.from({ length: stats.total ?? 0 }, (_, i) =>
          env.DB.prepare(
            "INSERT INTO question_attempts (session_id,subject,correct,time_s,created_at) VALUES (?,?,?,?,?)"
          ).bind(sessionId, subject, i < (stats.correct ?? 0) ? 1 : 0, null, now)
        )
      );
      if (stmts.length) await env.DB.batch(stmts);
    }
    return Response.json({ sessionId }, { headers: cors });
  } catch (err) {
    return Response.json({ error: "Failed to save session." }, { status: 500, headers: cors });
  }
}

async function handleStats(request, env, cors) {
  try {
    const [s, sub] = await Promise.all([
      env.DB.prepare("SELECT * FROM v_step_stats").all(),
      env.DB.prepare("SELECT * FROM v_subject_stats LIMIT 20").all(),
    ]);
    return Response.json({ steps: s.results, subjects: sub.results }, { headers: cors });
  } catch {
    return Response.json({ error: "Failed to fetch stats." }, { status: 500, headers: cors });
  }
}

const WARM_TARGETS = [
  { step: "Step 1",    subject: "Pharmacology",      difficulty: "Medium" },
  { step: "Step 1",    subject: "Pathology",          difficulty: "Hard"   },
  { step: "Step 2 CK", subject: "Internal Medicine",  difficulty: "Medium" },
  { step: "Step 2 CK", subject: "Emergency Medicine", difficulty: "Hard"   },
  { step: "Step 3",    subject: "Biostatistics & Epi",difficulty: "Medium" },
];

async function warmCache(env) {
  if (!env.ANTHROPIC_API_KEY) return;
  await Promise.allSettled(WARM_TARGETS.map(async ({ step, subject, difficulty }) => {
    try {
      const key = poolKey(step, subject, difficulty);
      const raw = await env.QUESTION_CACHE.get(key);
      const pool = raw ? JSON.parse(raw) : [];
      if (pool.length < 10) {
        const q = await callClaude(buildPrompt(step, subject, difficulty), env.ANTHROPIC_API_KEY, env);
        await addToPool(env.QUESTION_CACHE, key, q);
      }
    } catch (e) { console.error("Warm error:", e.message); }
  }));
}

export default {
  async fetch(request, env, ctx) {
    const origin = request.headers.get("Origin") ?? "";
    const cors   = corsHeaders(origin, env.ALLOWED_ORIGIN);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    const { pathname } = new URL(request.url);
    try {
      if (pathname === "/api/config"   && request.method === "GET")  return handleConfig(request, env, cors);
      if (pathname === "/api/question" && request.method === "POST") return handleQuestion(request, env, ctx, cors);
      if (pathname === "/api/session"  && request.method === "POST") return handleSession(request, env, cors);
      if (pathname === "/api/stats"    && request.method === "GET")  return handleStats(request, env, cors);
      if (pathname === "/health")
        return Response.json({ status: "ok", hasServerKey: !!env.ANTHROPIC_API_KEY, ts: Date.now() }, { headers: cors });
      return new Response("Not found", { status: 404, headers: cors });
    } catch (err) {
      console.error("Worker error:", err);
      return Response.json({ error: "Internal server error." }, { status: 500, headers: cors });
    }
  },
  async scheduled(event, env, ctx) { ctx.waitUntil(warmCache(env)); },
};
