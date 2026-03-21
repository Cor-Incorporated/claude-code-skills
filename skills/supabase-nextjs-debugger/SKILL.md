---
name: supabase-nextjs-debugger
description: >
  Diagnose and fix Supabase + Next.js App Router bugs on Vercel serverless.
  Use when: "Vercel 404/500", "Supabase RLS error", "pre-commit not found",
  "serverless state lost", "hydration error #418", "API works locally but not on Vercel",
  "env vars not working on Vercel", "NEXT_PUBLIC_ not available at runtime".
  Do NOT use for: general Next.js UI bugs, Supabase schema design, or non-Vercel deployments.
allowed-tools: [Read, Edit, Write, Bash, Grep, Glob, WebSearch]
---

# Supabase + Next.js on Vercel Debugger

## Critical: Verification Protocol

**NEVER claim a fix is complete without these checks:**

1. `npx tsc --noEmit` (zero errors)
2. `npx vitest run` (all pass)
3. `npx next build` (successful)
4. **curl test against production URL** (full API flow → 200)
5. **Vercel runtime logs check** (zero 404/500 after deploy)
6. **Ask user to test in browser** (curl success != browser success)

<important if="debugging Vercel environment variable issues or Supabase client silently failing on Vercel">
## Diagnostic Checklist

When a Supabase + Next.js app fails on Vercel, check these in order:

### 1. Environment Variables (Most Common)

`NEXT_PUBLIC_` vars are **inlined at build time** by Next.js. If env vars were added to Vercel AFTER the build, they won't be available in compiled code.

**Symptom**: API works with curl but Supabase operations silently fail; `isSupabaseConfigured` is false.

**Fix**: Add runtime fallback in the Supabase client:
```typescript
const supabaseUrl =
  process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL;
const supabaseAnonKey =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY;
```

**Action**: Tell user to add non-prefixed env vars (`SUPABASE_URL`, `SUPABASE_ANON_KEY`) to Vercel, OR redeploy after setting `NEXT_PUBLIC_` vars.
</important>

<important if="debugging intermittent API failures on Vercel or state lost between serverless invocations">
### 2. Serverless Statelessness

Vercel serverless functions do NOT share in-memory state across instances.

**Symptom**: API works intermittently (warm instance reuse) but fails on cold starts.

**Fix**:
- Never rely on in-memory `Map`/`Set` across requests
- All state must go through Supabase (or another external store)
- If using fallback in-memory store, understand it's per-instance only
</important>

<important if="debugging Supabase RLS policy errors, silent INSERT/SELECT/UPDATE failures, or upsert conflicts">
### 3. Supabase RLS Policy Conflicts

**Symptom**: INSERT succeeds (200) but subsequent SELECT returns no rows, or UPDATE fails silently.

**Common traps**:
- `WITH CHECK (revealed = true)` blocks UPDATE that sets `revealed = false`
- Upsert (`onConflict`) triggers UPDATE path, which may be blocked by restrictive RLS
- Missing SELECT policy (RLS enabled but no `FOR SELECT` policy)

**Fix**: Use INSERT + catch unique_violation (23505) instead of upsert when RLS is restrictive.

**Verify**: Check ALL policies on the table:
```sql
SELECT * FROM pg_policies WHERE tablename = 'your_table';
```
</important>

<important if="debugging 404 on page refresh or stale localStorage session data causing Supabase query misses">
### 4. Stale Data from Persistent Session IDs

**Symptom**: First visit works, subsequent visits/refreshes get 404. Works with new incognito window.

**Root cause**: `localStorage` persists a sessionId across page loads. Old rows in Supabase (e.g., `revealed = true`) conflict with new INSERTs (unique_violation ignored), and SELECTs filter by `revealed = false` -> no match -> 404.

**Fix**: Either:
- Generate fresh sessionId per page load (no localStorage persistence)
- Or handle stale rows: DELETE old row before INSERT (requires RLS DELETE policy)
- Or use `revealed` filter only in SELECT, not as the sole lookup key
</important>

<important if="fixing React hydration error #418 or SSR/client content mismatch">
### 5. React Hydration Error #418

**Symptom**: `Uncaught Error: Minified React error #418` in browser console.

**Root cause**: Text content differs between SSR and client hydration. Common causes:
- `useState(() => randomValue())` -- generates different values on server vs client
- `useState(() => uuid())` -- different UUID on each render
- `typeof window === "undefined"` conditional rendering with different text
- `new Date()` / `Math.random()` in render path

**Fix pattern**:
```typescript
// BAD: different values on SSR vs client
const [id] = useState(() => uuidv4());
const [personality] = useState(() => randomPersonalityType());

// GOOD: deterministic default on SSR, randomize in useEffect
const [id, setId] = useState("");
const [personality, setPersonality] = useState<Type>("default");

useEffect(() => {
  setId(uuidv4());
  setPersonality(randomPersonalityType());
}, []);
```
</important>

<important if="debugging useEffect race conditions or API calls firing before state initialization">
### 6. useEffect Initialization Order

**Symptom**: API call fires before client-side state is initialized.

**Root cause**: useEffect with `[]` dependency runs on mount, but deferred state (from another useEffect) hasn't been set yet.

**Fix**: Use the deferred state as a dependency:
```typescript
// BAD: runs before sessionId is set
useEffect(() => { startRound(); }, []);

// GOOD: waits for sessionId
useEffect(() => {
  if (!sessionId) return;
  startRound();
}, [sessionId]);
```
</important>

<important if="debugging silent Supabase query failures or undefined return values without error logs">
### 7. Silent Supabase Query Failures

**Symptom**: getPreCommit returns undefined but no error logged.

**Fix**: Always log Supabase errors before returning undefined:
```typescript
if (error) {
  console.error("[getPreCommit] query failed:", error.message, error.code);
  return undefined;
}
```
</important>

<important if="verifying a Supabase + Next.js fix before reporting completion">
## Verification Commands

```bash
# 1. Type check
npx tsc --noEmit

# 2. Tests
npx vitest run

# 3. Production build
npx next build

# 4. curl smoke test (replace URL and session)
SESSION=$(python3 -c 'import uuid; print(uuid.uuid4())')
curl -s -X POST https://YOUR_APP.vercel.app/api/start-round \
  -H "Content-Type: application/json" \
  -d "{\"session_id\":\"$SESSION\",...}" | jq .

curl -s -w "\nHTTP: %{http_code}\n" \
  -X POST https://YOUR_APP.vercel.app/api/play \
  -H "Content-Type: application/json" \
  -d "{\"session_id\":\"$SESSION\",...}"

# 5. Check Vercel runtime logs via MCP tools
# Filter by statusCode "404" and "500" after deploy
```
</important>

<important if="diagnosing Vercel deployment errors or runtime 404/500 via MCP tools">
## Vercel MCP Tools for Diagnosis

1. `list_projects` -> find project ID
2. `list_deployments` -> confirm latest deployment is READY
3. `get_deployment_build_logs` -> check for build errors
4. `get_runtime_logs` with `statusCode: "404"` or `"500"` -> find API errors
5. `get_runtime_logs` with `level: ["error"]` -> find application errors
</important>
