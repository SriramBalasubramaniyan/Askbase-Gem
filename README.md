# AskBase Gem

**Natural language query interface over any structured SQLite database, powered by the Gemini API.**

---

## What it does

AskBase Gem lets you ask plain-language questions about a SQLite database and get clear, factual answers.

```
User:        How many farmers are registered?
AskBase Gem: There are 30 farmers.

User:        Which farmer harvested the most kg?
AskBase Gem: Here's what I found:

             Name: Thiru Murugan
             Phone: 9695593601
             Gender: Female
             Address: 34 Main Street
             Total quantity kg: 4793.45

User:        Which crops have insurance claims filed?
AskBase Gem: Here's what I found — 10 in total:

             | Name    | Category | Season type |
             |---------|----------|-------------|
             | Cotton  | Fibre    | Kharif      |
             | Soybean | Oilseed  | Kharif      |
             | Banana  | Fruit    | Perennial   |
             | ...     | ...      | ...         |

User:        List all active loans
AskBase Gem: Here's what I found — 5 in total:

             **1.** Loan type: KCC
             Sanctioned amount: 192516.55
             Disbursed amount: 333377.21
             Interest rate pct: 9.4
             Disbursement date: 10 Oct 2022
             Due date: 10 Aug 2024
             Status: Active

             **2.** Loan type: KCC
             Sanctioned amount: 276691.76
             ...
```

Under the hood:
1. **GuardrailService** checks the question on-device first — length, repeats, prompt-injection attempts, and whether it's actually about the data at all — before anything is sent anywhere
2. The schema you define tells the model what tables and columns exist
3. **SchemaSelector** picks only the relevant tables using keyword scoring
4. **LlmService** calls the Gemini API to generate a SQLite SELECT query using only those tables, plus a compact summary of recent turns in the current chat so follow-up questions ("what about last month?") resolve correctly
5. **SqlColumnValidator** deterministically checks the query for hallucinated tables, columns, and enum values *before* it ever touches the database — feeding a specific correction back into a retry if it fails, up to 3 attempts total
6. The query runs against the local database (with a case-insensitivity safety net — see below)
7. **QueryService** builds the final answer directly from the returned rows — no LLM involved in this step at all (see "Deterministic answer assembly" below for why)
8. **ChatHistoryService** saves the exchange to the current conversation, naming it from its first question if this was a new chat

You can keep multiple named conversations at once — tap the history icon to switch between them or start a new one, same as any standard chat app (see "Chat history & multiple conversations" below).

---

## Architecture

```
User Question
     │
     ▼
GuardrailService.check()            ← on-device only, zero API calls: length,
     │                                 exact-repeat, prompt-injection patterns,
     │                                 and domain-relevance (via SchemaSelector)
     ├─ blocked → canned response shown, pipeline stops here, 0 tokens spent
     ▼
SchemaSelector.select()             ← word-boundary keyword scoring against the
     │                                 full schema, with generic-token dampening;
     │                                 returns a handful of relevant tables + FK deps
     ▼
┌─── Self-correction loop (1 initial attempt + up to 2 retries) ──────────────┐
│                                                                             │
│   LlmService.generateSql()         ← the only model call in the pipeline;   │
│        │                             a single Gemini API request per        │
│        │                             attempt, with compact recent-turn      │
│        │                             history (question + SQL only) for      │
│        │                             resolving follow-up references;        │
│        │                             connectivity-checked and cancellable   │
│        │                             before/during each request — see       │
│        │                             "Resilience" below                     │
│        ▼                                                                    │
│   SqlColumnValidator.check()       ← deterministic, no DB I/O: table/column │
│        │                             existence, undeclared-table detection, │
│        │                             enum-value validation                  │
│        ├─ fails → JoinPathFinder builds a literal FROM/JOIN skeleton if the │
│        │          failure involves two unrelated tables, appends it to the  │
│        │          error, retries with that context                          │
│        ▼                                                                    │
│   DbService.validateSql()          ← SELECT-only safety check               │
│        │                                                                    │
│        ▼                                                                    │
│   DbService.runSelect()            ← sqflite; text comparisons rewritten    │
│        │                             to COLLATE NOCASE                      │
│        ├─ fails → real SQLite error fed back into the next retry            │
│        ▼                                                                    │
│   Rows                                                                      │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     ▼
QueryService._buildDeterministicAnswer()   ← entire answer text (including the
     │                                        lead-in) built directly from the
     │                                        rows — no LLM involved
     ▼
Natural language answer
     │
     ▼
ChatHistoryService.saveMessages()   ← persisted to the current chat session;
                                       title set from the first question if
                                       this was a new chat
```

### Semantic schema selection

The full 50-table schema is too large to send on every request. `SchemaSelector` solves this by scoring each table against the user's question using:

- **Table name match** (weight: 10, whole-word) — the question mentions the table itself
- **Table description match** (weight: 3, whole-word)
- **Field name match** (weight: 5, whole-word) — the question mentions a specific column
- **Field description match** (weight: 2, whole-word)
- **Basic singular/plural stemming** — "farmers" also matches "farmer", "loans" also matches "loan", etc.
- **Generic-token dampening** — if a token matches more than ~30% of all tables in the schema (e.g. "name", "date", "id" — present almost everywhere), its match weight is automatically reduced for that query. This is computed fresh per-question from whatever schema is loaded, so it isn't a hardcoded stopword list and keeps working if you swap in a different domain.
- **Minimum score of 4** — a table needs either a real name match or more than one corroborating signal to be selected; a single incidental word appearing somewhere in a table's description is no longer enough on its own.
- **FK dependency inclusion** — any table referenced by a FK in a selected table is automatically included so JOINs remain valid.

Top 5 scoring tables are selected, plus their FK dependencies. This keeps the prompt small and cheap regardless of total schema size — fewer input tokens per request, which matters directly for the free-tier request/token budget (see "Gemini API" below).

In **debug builds**, the SQL disclosure panel shows which tables were selected for each query.

### Self-correction retry loop

`QueryService.ask()` doesn't give up after the first bad query. SQL generation, validation, and execution run in a loop of up to 3 total attempts — but the loop now handles two genuinely different kinds of failure differently, not just "retry the same way every time":

1. Generate SQL.
2. Check it deterministically with `SqlColumnValidator` (see below) — free, no database round-trip.
3. If that passes, run `DbService.validateSql()` (SELECT-only enforcement) and then actually execute it.
4. If validation or execution fails, the *specific* reason — not a generic "it failed" — is fed back into the next generation attempt: `"Your previous SQL failed to run: {sql}\n\nError: {reason}\n\nFix the query..."`. This is the **SQL self-correction** path — no delay before retrying, since there's nothing to wait out.
5. If the `LlmService.generateSql()` call itself fails (not a SQL problem — a network error, timeout, or a non-200 response from Gemini), the loop instead classifies *that* failure — see "Resilience" below — and only retries if it's the kind of error retrying can plausibly fix, with a backoff delay first.

If all attempts are exhausted (or a non-retryable failure hits immediately), the user gets an honest, specific message rather than a wrong answer — see "Resilience" and Troubleshooting below for what each failure type actually shows. In debug builds, every attempt's SQL and failure reason is logged (`developer.log`, tagged `QueryService`) so you can see exactly where a question is failing and why. Note each retry is a separate Gemini API request — a question that needs all 3 attempts costs 3x the requests of one that succeeds on the first try.

### Deterministic SQL validation (`SqlColumnValidator`)

A regex-based, non-executing check that runs *before* the query ever touches the database. Not a full SQL parser — it targets the specific hallucination patterns observed in practice, each verified against real failing queries before being shipped:

- **Column/table existence** — every `alias.column` reference and every unqualified column (for single-table queries) is checked against the real schema. Catches things like a query referencing `insurance.crop_id`, which doesn't exist.
- **Undeclared-table detection** — if a query references `crop.name` but its `FROM`/`JOIN` never actually brings in the `crop` table, that's flagged specifically (rather than silently skipped as an unrecognized alias) whenever the alias happens to be the exact name of a real table in the schema — a strong, low-false-positive signal that it's a forgotten JOIN.
- **Enum-value validation** — when a field's schema description documents its allowed values in parentheses (e.g. `"Loan status (Active, Repaid, Overdue, NPA)"`), any string-literal comparison against that column must use one of those exact values. A comparison like `claim_status = 'active'` against a column whose real values are `None/Filed/Approved/Rejected/Paid` is rejected before the query ever runs. This is deliberately separate from and doesn't overlap with case-insensitivity (below) — a value that's merely the wrong *case* of a real value is left alone here; only values that don't match *any* allowed value regardless of case are flagged.
- **Subquery-safe** — parenthesized `(SELECT ...)` blocks (e.g. inside an `IN (...)`) are masked out before any of the above runs. Without this, a subquery's own `FROM`/`JOIN` would make the outer query look like a multi-table query, which silently disables the single-table unqualified-column check for the *outer* query too.

Anything this validator can't confidently parse is left alone — it falls through to the real SQLite error instead, so it can only catch problems earlier, never introduce new false failures.

### Join-path hinting (`JoinPathFinder`)

When `SqlColumnValidator` catches a failure involving two tables that aren't directly connected by a foreign key, a plain "these tables aren't related" error wasn't enough for the model to work out a correct multi-hop join on its own in practice. `JoinPathFinder` runs a BFS over the schema's FK graph (built fresh from every table's `foreignKeyRef`, treated as undirected edges) and hands back a **literal, ready-to-copy** join structure:

```
crop and insurance are not directly related — do not join them directly to
each other. Use exactly this join structure instead: FROM crop JOIN sowing
ON sowing.crop_id = crop.crop_id JOIN insurance ON insurance.sowing_id =
sowing.sowing_id
```

The model's job on retry is reduced to "copy this in," not "figure out the schema topology."

### Deterministic answer assembly

`QueryService._buildDeterministicAnswer()` builds the entire final answer — including the lead-in sentence — directly from the query's result rows. **No LLM call is involved in producing the answer text at all.**

This wasn't the original design. Earlier versions asked the model to summarize the JSON rows in plain language, then later (after that produced inconsistent output) asked it to generate only a short data-free lead-in sentence while Dart supplied the facts. Both were tried and both failed the same way: **the exact same query and the exact same data would sometimes be handled correctly and sometimes not, across otherwise-identical runs** — and even when explicitly told never to state a number it hadn't been given, the model still occasionally fabricated one (a real example hit during development: a lead-in claiming *"10,000 registered farmers"* rendered directly above the correct, deterministically-computed *"There are 30 farmers."*). Telling the model not to do something turned out to be just another instruction it doesn't reliably follow — so the fix was architectural, not another prompt tweak: never give it the data to fabricate from in the first place. It also means every question costs exactly one Gemini request, not two.

What `_buildDeterministicAnswer` actually does with the rows:

- **Single aggregate value** (`COUNT`/`SUM`/`AVG`/`MIN`/`MAX` on one row, one column) → a complete sentence using the *real* table name (for `COUNT`, with correct singular/plural: "There are 30 farmers." / "There is 1 farmer.") or the *real* column name (for `SUM`/`AVG`/`MIN`/`MAX`, humanized: "The total disbursed amount is 1250000.5."), both pulled straight out of the generated SQL — not generic "matching records"/"the total" phrasing.
- **ID columns are always stripped** from displayed rows (any field named `id` or ending in `_id`) — never surfaced unless the user explicitly asked for one.
- **Every remaining column gets a readable label**, not a raw SQL result-column name — `sanctioned_amount` → "Sanctioned amount", `T1.name` → "Name". This also handles the case where the model skips the `AS` alias on an aggregate (`SUM(quantity_kg)` shows up as-is in raw SQLite results) — that's recognized and humanized the same way an aggregate sentence is: "Total quantity kg", not the raw function call.
- **Values are formatted, not dumped raw**: numbers are rounded to 2 decimal places with floating-point noise trimmed (`4793.450000000001` → `4793.45`, `100.0` → `100`), and any `YYYY-MM-DD` string is spelled out (`2022-10-10` → `10 Oct 2022`).
- **If every row is left with nothing after ID-stripping**, or **every remaining row's labeled details are identical** (e.g. a lone `status` column that just says "Pending" 11 times), an explicit fallback message is returned instead of a misleadingly confident answer — which doubles as a visible signal that the generated SQL under-selected columns, rather than silently glossing over it.
- **A single row** renders as one labeled line per field (like a small profile card — `Name: ...`, `Phone: ...`, `Total quantity kg: ...`, one per line).
- **Multiple rows, ≤5 columns** (`QueryService._maxTableColumns`) render as a real **GFM markdown table** — one column per selected field, values lined up for scanning instead of wrapping into one long line per row. `chat_bubble.dart` renders it with `tableColumnWidth: const FlexColumnWidth()`, which divides the bubble's width evenly across columns, so a table can never force the bubble wider than its constraint or overflow off-screen — long cell text wraps within its cell instead, the same way the rest of the answer text does. Rendering GFM table syntax (`| a | b |`) also requires `extensionSet: md.ExtensionSet.gitHubFlavored` on the `MarkdownBody`, since tables aren't part of base CommonMark — off by default in `flutter_markdown`.
- **Multiple rows, >5 columns** render as one numbered block per row instead — `**1.** Loan type: KCC` followed by the rest of that row's fields, one per line — rather than a table, since past 5 columns equal-share division starts squeezing headers like "Disbursement date" into cells too narrow to read comfortably. This is the same per-row card layout the single-row case above uses, just numbered since there's more than one.
- **No artificial cap** on row count either way — every row the query returns is shown.

`LlmService` has exactly one model-facing method: `generateSql()`. There is no `summarizeResults()` or results-lead-in generator anymore.

### Query-shape correctness rules

Two rules live directly in `LlmService`'s system prompt to fix shapes the model got wrong often enough in practice to be worth naming explicitly, rather than leaving to general "write good SQL" instructions:

- **Singular superlatives get `LIMIT 1`.** A question like "which farmer harvested the most kg?" is asking for exactly one entity, not a ranked list — but without an explicit rule, the model would inconsistently pick anywhere from `LIMIT 1` to the default `LIMIT 100` for the same question across runs. The prompt now explicitly ties `LIMIT 1` to superlative wording ("the most", "the highest", "the best", etc.) *unless* the question also asks for a list, several results, or a specific "top N" — those still get the default `LIMIT 100`.
- **Boolean-as-integer columns are compared as integers.** A field described as `"1 if X, 0 if Y"` or `"1 if X, 0 otherwise"` (this schema's convention for flags like `attended`, `is_active`, `certificate_issued`) is an integer column, not a text status field — but nothing previously told the model that, so it would sometimes guess a string comparison like `attended = 'Yes'`, which matches nothing and silently returns zero rows. The prompt now explicitly calls out this description pattern and requires comparing against the integer `1`/`0` instead.

### Gemini API

| Item | Value |
|---|---|
| Provider | Google Gemini Developer API |
| Endpoint | `https://generativelanguage.googleapis.com/v1beta` (the free-tier REST endpoint — no billing account, no Google Cloud project setup required) |
| Model | `gemini-flash-lite-latest` — always resolves to the newest Flash-Lite model, the lowest-token-cost / highest-free-quota tier Gemini offers |
| Auth | Personal API key, entered once via `ApiKeyScreen`, stored on-device with `flutter_secure_storage` (Keychain on iOS, Keystore-backed encrypted storage on Android) |
| Requests per question | Exactly 1 per attempt (up to 3 with retries) |
| Internet after setup | **Required** — every question makes a live API call |

Get a free key at [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) — no credit card needed. The key is sent as the `x-goog-api-key` header on every request and never leaves the device except in that request.

**Why Flash-Lite?** SQL generation from a handful of pre-filtered tables is a short, structured, low-reasoning task — exactly what Flash-Lite is built for. It carries the most generous free-tier rate limits of any Gemini model, which matters directly since every question in this app is a live API call rather than a one-time download.

**Changing your key:** tap the key icon in the chat screen's top bar at any time to clear the stored key and re-enter a new one.

### Resilience: retries, connectivity, and cancellation

Every `LlmService.generateSql()` failure now throws one of three typed exceptions instead of a generic error, so `QueryService`'s retry loop can react appropriately instead of treating every failure the same way:

- **`GeminiApiException`** — any Gemini API-level failure (network error, non-200 response, malformed response body). Carries `isRetryable`: `429` (rate limit) and `5xx` (server-side) responses, plus timeouts and connection failures, are retryable — the same request often succeeds a moment later. `401`/`403` (bad or revoked key) and `400` (malformed request) are **not** retryable — they'll fail identically every time, so the loop returns immediately with a specific message instead of burning the remaining attempts. This also avoids a subtler bug: retrying used to frame *every* failure to the model as "your previous SQL failed, fix it" — nonsensical for an auth error that has nothing to do with SQL.
- **`NoConnectivityException`** — thrown before the HTTP call is even attempted, via a `connectivity_plus` check (`Connectivity().checkConnectivity()`) at the start of every attempt. This is a cheap local OS-level check, not a real network probe, so it can be wrong (e.g. connected to Wi-Fi with no real internet behind it, such as a captive portal) — but it correctly catches the common case (airplane mode, no signal) instantly instead of waiting out the full `ApiConfig.requestTimeout` (30s) first.
- **`GenerationCancelledException`** — thrown when a `CancellationToken` is cancelled mid-request. `QueryService.ask()` accepts an optional `cancelToken`; `AppState` creates one per `sendMessage()` call and exposes `cancelCurrentQuery()`, wired to a stop button in `InputBar` that appears in place of the send button while a response is generating. A cancelled request shows no error and isn't retried — `AppState` removes the "thinking" placeholder entirely rather than leaving an empty bubble behind.

**Backoff:** a retryable `GeminiApiException` waits before the next attempt — `600ms × 2^(attempt-1)` (plain exponential backoff), so attempt 2 waits 600ms and attempt 3 waits 1.2s. This delay is *not* applied to SQL self-correction retries (wrong column, failed validation) — those aren't rate-limit or network problems, so there's nothing to wait out; only a network/API-level retryable failure incurs it.

**Cancellation timing caveat:** cancellation is checked at the *start* of each `generateSql()` call and by aborting the `http.Client` mid-request. If cancellation happens while the loop is sleeping through a backoff delay (rare — only reachable after a retryable API error), the wait still completes before the cancellation is recognized, since `Future.delayed` itself isn't interruptible. In practice this adds at most ~1.2s.

### Guardrails (`GuardrailService`)

Every question passes through `GuardrailService.check()` **before** `QueryService` ever calls `LlmService.generateSql()`. All of it runs on-device, so a blocked question costs zero Gemini requests and zero tokens. Checks run cheapest-first and short-circuit on the first failure:

1. **Empty input** — nothing sent.
2. **Length cap** (`GuardrailService.maxQuestionLength`, 400 characters) — stops an accidentally-pasted wall of text from becoming an oversized request.
3. **Exact-repeat guard** — if the question is verbatim identical to the immediately preceding one in this chat, it's rejected with a pointer back to the existing answer instead of re-querying the API for output that would be identical.
4. **Prompt-injection patterns** — a short list of phrases ("ignore previous instructions", "reveal your prompt", "you are now...", "jailbreak", etc.) is checked before anything else that would otherwise call the model; a match is rejected immediately. This is a cheap first line of defense, not a replacement for the system prompt's own hardening (see below).
5. **Domain relevance** — reuses `SchemaSelector.maxScore()` (the same scoring `select()` uses to pick tables) to check whether the question actually relates to something in the schema. A question that scores 0 and isn't a short, context-dependent follow-up (≤40 characters, asked right after another question) is rejected outright — e.g. "what's the weather today" never reaches Gemini.

On top of the pre-flight guardrail, two more layers of defense run independently:

- **Send-cooldown** (`GuardrailService.minSendInterval`, 1.2s) — enforced in `AppState.sendMessage()` itself, before the guardrail check even runs. Absorbs accidental double-taps on send silently (no message shown, nothing recorded) rather than firing two identical requests.
- **System-prompt hardening** — `LlmService`'s system prompt explicitly instructs the model to treat the question and conversation history as data, never as instructions, and to answer `OUT_OF_SCOPE` for anything that tries to override its rules. This is defense-in-depth for whatever the on-device injection-pattern list doesn't catch — it costs one request (not zero, unlike the pre-flight guardrail), but it's the backstop for cases guardrail #4 above doesn't have a pattern for yet.

Other token-reduction choices, alongside the guardrails above:
- `maxOutputTokens` capped at 200 in every request (SQL for a handful of pre-filtered tables never needs more).
- `SchemaSelector` still limits every request to a handful of relevant tables regardless of total schema size (see "Semantic schema selection" above) — fewer input tokens per request.
- Conversation history sent to the model is capped to the last `LlmService.maxHistoryTurns` (3) turns, and only as compact `question + generated SQL` pairs — never the full narrative answer or raw result rows (see "Chat history" below).

### Chat history & multiple conversations

AskBase Gem keeps multiple named conversations, like a standard chat app — not just one running transcript.

- **New chat** — the add-comment icon in the top bar (or "New chat" in the drawer) starts a blank, unsaved draft. It only becomes a real, listed conversation once its first message is actually sent — an empty "New chat" never shows up in the history list, matching how most production chat apps behave.
- **Chat topic / title** — generated entirely from the conversation's first question, truncated to a word boundary (`ChatHistoryService.titleFromQuestion()`). No model call is involved in naming a chat — this is a deliberate token-saving choice, not a missing feature.
- **History drawer** — the hamburger icon (top-left, automatically added by Flutter whenever a `Scaffold` has a `drawer`) opens `ChatHistoryDrawer`, listing every saved conversation by title and last-updated time, most recent first. Tapping one loads its full message history; the small × on each row deletes that conversation (with a confirmation dialog).
- **Deleting the open chat always lands on a blank draft**, never on whatever chat happens to be next in the list. This was a real bug in an earlier version — deleting the current chat fell back to silently loading the next-most-recent saved one, which felt like "popping a stack" rather than the delete actually taking effect. `AppState.deleteChat()` now resets to an unsaved draft unconditionally when the deleted chat was the one open, regardless of how many other chats remain.
- **Persistence** — handled by `ChatHistoryService`, entirely via `shared_preferences` (no new dependency): a lightweight index (id, title, last-updated) is stored separately from each conversation's full message list, so opening the drawer never has to load every conversation into memory — only the index. A conversation's full messages are loaded lazily, only when it's opened.
- **In-context follow-ups** — asking "what about last month?" right after "list active loans" works because `AppState` builds a compact history of the current chat's prior `question → generated SQL` pairs and passes it to `LlmService.generateSql()`, which includes it in the prompt so the model can resolve the reference. See "Guardrails" above for how this is kept small.
- **Old-chat pruning** — `ChatHistoryService` automatically drops conversations older than 90 days (and caps total stored chats at 200) the next time the index is saved, so local storage doesn't grow unbounded over long-term use.

### Database freshness

`DbService.init()` copies the bundled `.db` asset into the app's documents directory, and **re-copies it** (rather than only ever copying once) when:
- no copy exists yet (first run),
- the bundled asset's byte size differs from what was last copied (tracked via `shared_preferences` — a cheap, dependency-free way to detect "the seed data changed"), or
- this is a debug build, so active development against a changing database never silently keeps serving stale data on a device that had the app installed before the latest asset was bundled.

> **Why this matters:** the original "only copy if the file doesn't already exist" logic meant any device that had the app installed before a seed-data update would run against the old copy forever — the exact same query could return different results from the live app vs. a fresh read of the current asset, with no error or indication why.

### Database

The bundled `agri.db` is a comprehensive agricultural management database with **50 tables** and **1047 records** covering the full farming lifecycle:

| Domain | Tables |
|---|---|
| Geography | `state`, `district`, `village` |
| Land & Soil | `soil_type`, `land_document`, `soil_test` |
| Farmer & Farm | `farmer`, `farm` |
| Crops | `crop`, `variety`, `grade`, `season` |
| Production | `sowing`, `harvest` |
| Inputs | `fertilizer`, `fertilizer_application`, `pesticide`, `pesticide_application`, `input_supplier`, `input_purchase` |
| Water & Weather | `irrigation`, `weather_log` |
| Machinery & Labour | `equipment`, `equipment_usage`, `labour`, `labour_attendance` |
| Storage & Trade | `warehouse`, `stock`, `buyer`, `sale`, `market_price`, `delivery`, `transport` |
| Finance | `bank_account`, `loan`, `insurance`, `payment`, `subsidy` |
| Government | `government_scheme`, `scheme_enrollment` |
| Pest & Disease | `crop_disease`, `disease_report` |
| Advisory & Compliance | `advisory`, `inspection`, `certification` |
| Community | `cooperative`, `cooperative_member`, `training`, `training_attendance`, `feedback` |

---

## Project structure

```
askbase_gem/
├── assets/
│   └── agri.db                        ← bundled database (replace to swap domain)
│
├── lib/
│   ├── main.dart                      ← entry point, routing
│   │
│   ├── config/
│   │   └── api_config.dart            ← Gemini base URL, model name, timeout
│   │
│   ├── models/
│   │   ├── db_schema_model.dart       ← FieldDef, TableSchema, DatabaseSchema
│   │   ├── chat_message.dart          ← ChatMessage (JSON-serializable for persistence)
│   │   └── chat_session.dart          ← ChatSummary — history-drawer list entry
│   │                                     (id, title, last-updated)
│   │
│   ├── schema/
│   │   └── agri_schema.dart           ← swappable schema definition
│   │
│   ├── services/
│   │   ├── db_service.dart            ← sqflite access, SQL validation, case-insensitive
│   │   │                                 rewrite, DB freshness/re-copy logic
│   │   ├── schema_selector.dart       ← keyword-scoring table selection; also exposes
│   │   │                                 maxScore() for the domain-relevance guardrail
│   │   ├── sql_column_validator.dart  ← deterministic table/column/enum-value check
│   │   ├── join_path_finder.dart      ← BFS over the FK graph for join-path hints
│   │   ├── guardrail_service.dart     ← pre-flight, on-device checks (length,
│   │   │                                 exact-repeat, prompt-injection, domain
│   │   │                                 relevance) — runs before any API call
│   │   ├── chat_history_service.dart  ← persists the chat index + per-chat messages
│   │   │                                 via shared_preferences; derives chat titles
│   │   ├── llm_service.dart           ← Gemini API key storage + SQL generation
│   │   │                                 (the only model-facing service — no
│   │   │                                 summarization here anymore), history-aware
│   │   └── query_service.dart         ← pipeline orchestrator + deterministic
│   │                                     answer assembly
│   │
│   └── ui/
│       ├── app_theme.dart             ← colors, typography, theme
│       ├── app_state.dart             ← ChangeNotifier, all app state — chat
│       │                                 sessions, guardrail wiring, send-cooldown
│       ├── screens/
│       │   ├── splash_screen.dart
│       │   ├── api_key_screen.dart    ← one-time Gemini API key entry
│       │   └── chat_screen.dart       ← delete-chat button disabled while a
│       │                                 response is generating; key icon to
│       │                                 change the stored API key; new-chat icon
│       └── widgets/
│           ├── chat_bubble.dart       ← SQL disclosure + debug table panel;
│           │                             renders GFM markdown tables with
│           │                             FlexColumnWidth (can't overflow the bubble)
│           ├── input_bar.dart
│           ├── empty_chat.dart
│           ├── thinking_indicator.dart
│           ├── chat_history_drawer.dart ← chat list + new-chat action (Scaffold drawer)
│           └── error_screen.dart
```

---

## Getting started

### Prerequisites

- Flutter 3.41.1 (stable), Dart 3.8.x
- A free Gemini API key — get one at [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey)
- Internet access on the device (every question is a live API call)

### 1. Clone and install dependencies

```bash
git clone https://github.com/SriramBalasubramaniyan/Askbase-Gem.git
cd askbase_gem
flutter pub get
```

### 2. Build and run

```bash
flutter run          # debug — shows selected tables in SQL panel, verbose SQL-attempt logging
flutter run --release # release — selected tables hidden
flutter build apk --release
```

On first launch, paste your Gemini API key into the setup screen. It's saved on-device and only asked for again if you tap the key icon in the chat screen to clear it.

---

## Swapping to a different database

AskBase Gem is domain-agnostic. To use it with any other SQLite database:

### Step 1 — Replace the database file

```bash
cp your_new_database.db assets/agri.db
```

### Step 2 — Create a new schema file

Create `lib/schema/your_schema.dart`. Follow the same structure as `agri_schema.dart`. `SchemaSelector`, `SqlColumnValidator`, and `JoinPathFinder` all work automatically with any schema — no changes needed there.

### Step 3 — Update main.dart (one line)

```dart
import 'schema/your_schema.dart';
create: (_) => AppState(yourSchema)..initialize(),
```

### Step 4 — Update suggestions in empty_chat.dart

Edit the `_suggestions` list in `lib/ui/widgets/empty_chat.dart`.

---

## Schema definition guide

### FieldDef parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | `String` | ✅ | Exact column name in SQLite |
| `type` | `FieldType` | ✅ | `integer`, `text`, `real`, `blob` |
| `description` | `String` | ✅ | Used by SchemaSelector for keyword matching, injected into the LLM prompt, AND parsed by `SqlColumnValidator` for enum-value checking |
| `isPrimaryKey` | `bool` | ❌ | Marks field as PK |
| `foreignKeyRef` | `String?` | ❌ | `"table.column"` — used for JOIN awareness, FK dependency resolution, and `JoinPathFinder`'s pathfinding |

### Writing good descriptions

Descriptions serve three purposes now: they help `SchemaSelector` find the right tables, they help the model understand column semantics, and — for enum/status-style columns — they're deterministically parsed to validate generated SQL.

```dart
// ❌ Vague — selector won't find it, model won't understand it,
// and there's no enum list to validate against
FieldDef(name: 'qty', type: FieldType.real, description: 'Quantity')

// ✅ Specific — selector finds "loan" queries, model writes correct SQL
FieldDef(
  name: 'sanctioned_amount',
  type: FieldType.real,
  description: 'Amount sanctioned for the loan in rupees.',
)
```

**For enum/status-style text columns, list the exact stored values in parentheses** — e.g. `"Loan status (Active, Repaid, Overdue, NPA)."` This isn't just documentation: `SqlColumnValidator` parses this exact format (a parenthetical group with 2+ comma-separated items, each under 30 characters) and will reject any generated SQL that compares this column to a value not in that list, before it ever reaches the database. `DbService`'s `COLLATE NOCASE` rewrite separately covers you if the casing doesn't match exactly — the two checks are complementary and don't overlap.

**For boolean flags stored as an integer, write the description as `"1 if X, 0 if Y"` or `"1 if X, 0 otherwise"`** — e.g. `"1 if farmer attended, 0 if absent."` `LlmService`'s system prompt recognizes this exact phrasing and tells the model to compare the column against the integer `1`/`0`, not a text value — without it, the model has been observed guessing `'Yes'`/`'No'`-style string comparisons against a genuinely integer column, which silently return zero rows since that value never exists in the data.

### Token budget

Gemini's context window is far larger than this app will ever need, so there's no hard prompt-fitting limit to design around — but `SchemaSelector` still keeps only a handful of relevant tables in every request, since fewer input tokens means less of the free-tier's per-minute token budget consumed per question. You can safely have 100+ tables in the schema — only the relevant subset is ever sent to the model. `maxOutputTokens` is capped at 200 in `LlmService`, comfortably more than a generated SQL query needs, to keep each response small and fast.

---

## Security

- Only `SELECT` statements are allowed. `DROP`, `DELETE`, `UPDATE`, `INSERT`, `ALTER`, `CREATE`, `REPLACE`, `TRUNCATE`, `ATTACH`, `DETACH`, `PRAGMA` are all rejected.
- The database is opened and protected at the query validation layer via `validateSql()`.
- The Gemini API key is stored on-device via `flutter_secure_storage` — Keychain on iOS, an encrypted Keystore-backed store on Android. A version of this app before this change stored it in plain `shared_preferences`; `LlmService._loadApiKey()` migrates a key found there to secure storage automatically on first read and deletes the old copy, so existing installs don't get logged out.
- Only the question text and the selected table/column names (never row data) are sent to Google as part of SQL generation. Query *results* never leave the device — the answer is assembled from local database rows in Dart.
- `GuardrailService` rejects obvious prompt-injection phrasing ("ignore previous instructions", "reveal your prompt", etc.) before a question ever reaches the API, and the system prompt itself instructs the model to treat the question and conversation history as data, never as instructions — two independent layers, since neither one alone is airtight against a sufficiently creative rephrasing.
- Saved chat history (titles and full conversations, including generated SQL) is stored on-device via `shared_preferences` — a lower trust level than the API key above (plain storage vs. Keychain/Keystore-encrypted), which is an intentional trade-off: `flutter_secure_storage` is slower per read/write and isn't the right tool for a growing, frequently-read dataset like chat history the way it is for a single small credential.

---

## Troubleshooting

### Wrong tables selected for a query
- The SchemaSelector uses keyword matching. If results are wrong, improve field/table descriptions in the schema file — specific, distinctive wording scores better than generic terms (generic terms that appear in most tables are automatically dampened).
- In debug mode, expand the SQL panel to see which tables were selected, or call `SchemaSelector.instance.debugSelectionInfo(question, schema)` directly to see per-table scores and matched tokens.

### "I couldn't come up with a working query" after asking something reasonable
- Check the debug log (tagged `QueryService`) — every attempt's SQL and the specific reason it failed is logged. Common causes: the schema genuinely doesn't have the data being asked about, a required JOIN spans more hops than `JoinPathFinder` can bridge usefully, or the model repeated the same mistake across all 3 attempts despite an accurate correction.

### Answer says results "contain no descriptive details" or "the same for every one"
- This is `QueryService`'s deterministic fallback firing — it means the generated SQL technically ran and returned rows, but after stripping ID columns there was nothing meaningful left to show (or every row's remaining value was identical). This is a visible signal that the SQL-generation step under-selected columns for that question — try rephrasing to explicitly ask for the columns you want (e.g. "list active loans **with their type and amount**").

### Query returns "No records found" but the data should exist
- Check for a **casing mismatch** first — `DbService` applies `COLLATE NOCASE` automatically to `=`/`!=`/`<>` string comparisons, but not to `IN (...)` lists.
- Check for a **wrong enum value** — if the value used isn't one of the column's documented allowed values, `SqlColumnValidator` should already catch this before execution and trigger a retry; if it's still getting through, double-check the field's `description` lists the allowed values in the exact parenthetical format described above.
- Check whether the question uses a **relative date** (e.g. "last 3 months") against **static seed data** — `DATE('now', '-3 months')` resolves against the real device clock, so if your seed data's dates don't extend into the actual present, relative-date queries will legitimately return nothing. Either refresh the seed data's date range periodically, or ask with an explicit date range instead of a relative one.
- Confirm exact names first: "what farmers are there?" before filtering by a specific name.

### "The AI model encountered an error while generating a query"
- Usually a Gemini API problem, not a SQL problem. Check the `errorDetail` on the result (or the debug log) for the underlying HTTP status:
  - **401 / `API_KEY_INVALID`** — the stored key is wrong or has been revoked. As of the retry classification in "Resilience" above, this now fails on the *first* attempt rather than being retried 3 times — you'll see a specific "your API key looks invalid" message pointing at the key icon, not the generic error.
  - **429 / `RESOURCE_EXHAUSTED`** — the free tier's requests-per-minute or requests-per-day limit was hit. This is retried automatically with backoff (see "Resilience" above) before surfacing an error — if you still see this message, all 3 attempts hit the limit. Wait (RPM limits clear within a minute; RPD resets at midnight Pacific) or reduce request volume.
  - **Network error / timeout** — the request exceeded `ApiConfig.requestTimeout` (30s), or a connection failure occurred mid-request. Also retried with backoff before surfacing. Unlike the old on-device model, AskBase Gem now needs a live connection for every question.

### App can't reach Gemini at all
- If you're actually offline, this is now detected *before* the request is attempted (via a `connectivity_plus` check — see "Resilience" above) rather than after waiting out the full 30s timeout, so you should see a "You're offline" message quickly rather than a generic failure after a long pause. If you're instead seeing the generic error after a delay, you likely have a network connection that reports as "connected" but isn't actually reaching the internet (e.g. a captive portal) — the connectivity check can't detect that case, only genuine no-signal/airplane-mode.
- Confirm your API key was actually saved: clear it via the key icon and re-enter it.

### "I can only answer questions about the data in this database" for a question that seems on-topic
- This is `GuardrailService`'s domain-relevance check, not Gemini — it means `SchemaSelector.maxScore()` found no table/column match for the question (and it also didn't qualify as a short context-dependent follow-up). Try rephrasing with a term closer to an actual table/field name or description; if it keeps happening for genuinely on-topic questions, the schema's field descriptions may need more specific wording (see "Wrong tables selected" above — the same scoring is used for both).

### A question was rejected with "I can't follow instructions that change how I operate"
- The question matched one of `GuardrailService`'s prompt-injection patterns (phrases like "ignore previous instructions", "reveal your prompt", "you are now..."). This check has no awareness of intent — a genuine question that happens to contain one of these phrases (rare, but possible) will also be blocked. Rephrase without that wording.

### My question was silently ignored (nothing happened)
- Likely the send-cooldown (`GuardrailService.minSendInterval`, 1.2s) absorbing an accidental double-tap on send — by design, this case shows no message at all. Wait a moment and send again.

### Some answers show a table, others show a numbered list instead
- This is intentional, not inconsistent — `QueryService` renders a real markdown table when a result has 5 or fewer columns (`_maxTableColumns`), and falls back to a numbered `**1.** field: value` block per row above that. A table with too many columns would squeeze headers into unreadably narrow cells on a phone-width screen, so the block layout takes over instead. See "Deterministic answer assembly" above.

### I tapped stop but the response kept generating briefly
- Expected in one case: if the app was mid-backoff-wait after a retryable API error (see "Resilience" above), the cancellation is only recognized once that wait finishes and the next attempt starts — `Future.delayed` itself can't be interrupted. This adds at most ~1.2s. Outside of that window, cancellation should take effect immediately.

---

## Known limitations

- **Requires internet for every question.** Unlike the original on-device design, each question is a live Gemini API call — there's no offline fallback.
- **Free-tier rate limits.** `gemini-flash-lite-latest` has the most generous free-tier limits Gemini offers, but they're still finite (requests-per-minute and requests-per-day caps, reset details vary by Google's current published limits). Heavy or bursty use can hit a 429 — see Troubleshooting above.
- **Repeated identical mistakes on retry.** The self-correction loop feeds back a specific, accurate error, but the model doesn't always act on it — occasionally it repeats the exact same wrong column/table name across all 3 attempts even when told precisely what the correct one is. `SqlColumnValidator` and `JoinPathFinder` measurably reduce how often this happens (especially for join-path reasoning), but don't eliminate it. Treat repeated "couldn't come up with a working query" failures on a specific question as a signal worth investigating via the debug log, not always a bug in the validation layer.
- **`IN (...)` lists aren't case-normalized or enum-checked.** Both `COLLATE NOCASE` rewriting and enum-value validation currently only cover direct `=`/`!=`/`<>` string comparisons.
- **Deterministic answers favor correctness over natural phrasing.** Since the answer text is built entirely in Dart rather than paraphrased by the model, multi-row answers render as a markdown table (≤5 columns) or a numbered per-row block (more columns) rather than free-form prose. This was a deliberate trade after LLM-generated summaries proved unreliable — see "Deterministic answer assembly" above.
- **The table/block split is a fixed column-count threshold (5), not a judgment call.** A result with exactly 6 columns falls to the per-row block layout even though a table might still have read fine; there's no attempt to measure actual content width per column, just column count.
- **The domain-relevance guardrail is heuristic, not semantic.** It reuses `SchemaSelector`'s keyword scoring, so a genuinely on-topic question phrased with none of the schema's vocabulary can be rejected before it ever reaches Gemini (a false rejection costs nothing, but is still a UX rough edge — see Troubleshooting above).
- **The prompt-injection filter is a short, pattern-level list**, not a general-purpose jailbreak detector — it catches common phrasings, not every way to phrase an override attempt. The system prompt's own hardening is the deeper backstop, not this list.
- **Chat titles never update after creation.** A title is fixed from the conversation's first question and doesn't change even if the conversation's topic drifts significantly in later turns — there's no rename option currently.
- **Value formatting is heuristic, not type-aware.** `_formatValue` decides how to display a cell purely from its shape: any string matching `YYYY-MM-DD` is treated as a date and spelled out, and every number is rounded to 2 decimal places. A text column that happens to contain a literal `YYYY-MM-DD`-shaped string for a non-date reason would still get reformatted as a date; a numeric ID-like column that wasn't caught by the `_id`/`id` name-based strip (see "Deterministic answer assembly" above) would get rounded like any other number. Neither has come up in practice with this schema's naming conventions, but it's worth knowing if you swap in a very differently-named database.
- **The connectivity check is a local OS-level check, not a real internet probe.** `connectivity_plus` reports the device is *associated with* a network (Wi-Fi/cellular), not that the network actually reaches Gemini's servers — a captive portal or a genuinely dead upstream link will still hit the full request timeout before failing, rather than being caught instantly.
- **Backoff is short and fixed.** Retryable API errors wait `600ms × 2^(attempt-1)` between attempts — enough to smooth over a brief blip or a momentary rate-limit, but not a long enough window to wait out a sustained outage or a `429` that takes longer than a couple seconds to clear.
- **Cancellation isn't instant during a backoff wait.** If a retryable API error triggers a backoff delay, cancelling during that ~600ms–1.2s window doesn't take effect until the wait finishes and the next attempt starts — see Troubleshooting above.

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `sqflite` | ^2.3.3 | SQLite access |
| `http` | ^1.2.2 | Gemini API requests |
| `connectivity_plus` | ^6.0.5 | Pre-flight network check before each Gemini request |
| `flutter_secure_storage` | ^9.2.2 | Gemini API key storage (Keychain/Keystore-backed) |
| `path_provider` | ^2.1.3 | App documents directory |
| `provider` | ^6.1.2 | State management |
| `google_fonts` | ^6.3.3 | DM Sans |
| `flutter_markdown` | ^0.7.3 | Markdown rendering — labeled lists and GFM tables in answers |
| `shared_preferences` | ^2.2.3 | DB freshness tracking, chat history persistence |
| `intl` | ^0.19.0 | Timestamp formatting, chat history date labels |

All validation and guardrail logic (`SqlColumnValidator`, `JoinPathFinder`, `GuardrailService`, `ChatHistoryService`) is plain Dart with no additional package dependencies beyond what's listed above.

`chat_bubble.dart` also imports `package:markdown/markdown.dart` for `md.ExtensionSet.gitHubFlavored` (needed to render table syntax). This resolves as a transitive dependency of `flutter_markdown` without needing its own `pubspec.yaml` entry — but if a future `flutter_markdown` upgrade ever changes that, add `markdown: ^7.2.2` directly.

---

## Flutter SDK

**Required: Flutter 3.41.1 (stable), Dart 3.8.x**

No native ABI constraints or minSdk requirements beyond Flutter's own defaults — there's no on-device inference runtime anymore, so any Android/iOS target Flutter itself supports will work.

---

## Credits

- LLM: [Gemini API](https://ai.google.dev/gemini-api/docs) by Google