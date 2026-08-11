# AskBase Gem

**Natural language query interface over any structured SQLite database, powered by the Gemini API.**

---

## What it does

AskBase Gem lets you ask plain-language questions about a SQLite database and get clear, factual answers.

```
User:        How many farmers are registered?
AskBase Gem: There are 30 farmers.

User:        List all active loans
AskBase Gem: Here's what I found — 5 in total:
             - Term Loan, 333377.21, Active
             - KCC, 191641.95, Active
             - Term Loan, 365264.69, Active
             - Cooperative Loan, 451653.32, Active
             - Cooperative Loan, 477099.92, Active
```

Under the hood:
1. The schema you define tells the model what tables and columns exist
2. **SchemaSelector** picks only the relevant tables using keyword scoring
3. **LlmService** calls the Gemini API to generate a SQLite SELECT query using only those tables
4. **SqlColumnValidator** deterministically checks the query for hallucinated tables, columns, and enum values *before* it ever touches the database — feeding a specific correction back into a retry if it fails, up to 3 attempts total
5. The query runs against the local database (with a case-insensitivity safety net — see below)
6. **QueryService** builds the final answer directly from the returned rows — no LLM involved in this step at all (see "Deterministic answer assembly" below for why)

---

## Architecture

```
User Question
     │
     ▼
SchemaSelector.select()             ← word-boundary keyword scoring against the
     │                                 full schema, with generic-token dampening;
     │                                 returns a handful of relevant tables + FK deps
     ▼
┌─── Self-correction loop (1 initial attempt + up to 2 retries) ──────────────┐
│                                                                             │
│   LlmService.generateSql()         ← the only model call in the pipeline;   │
│        │                             a single Gemini API request per        │
│        │                             attempt                                │
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

`QueryService.ask()` doesn't give up after the first bad query. SQL generation, validation, and execution run in a loop of up to 3 total attempts:

1. Generate SQL.
2. Check it deterministically with `SqlColumnValidator` (see below) — free, no database round-trip.
3. If that passes, run `DbService.validateSql()` (SELECT-only enforcement) and then actually execute it.
4. If any step fails, the *specific* reason — not a generic "it failed" — is fed back into the next generation attempt: `"Your previous SQL failed to run: {sql}\n\nError: {reason}\n\nFix the query..."`

If all 3 attempts fail, the user gets an honest `"I couldn't come up with a working query for '{question}' right now"` rather than a wrong answer. In debug builds, every attempt's SQL and failure reason is logged (`developer.log`, tagged `QueryService`) so you can see exactly where a question is failing and why. Note each retry is a separate Gemini API request — a question that needs all 3 attempts costs 3x the requests of one that succeeds on the first try.

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
- **If every row is left with nothing after ID-stripping**, or **every remaining row is identical** (e.g. a lone `status` column that just says "Pending" 11 times), an explicit fallback message is returned instead of a misleadingly confident answer — which doubles as a visible signal that the generated SQL under-selected columns, rather than silently glossing over it.
- **Otherwise**, one row → a plain sentence; multiple rows → a markdown bullet list, one bullet per row, with **no artificial cap** — every row the query returns is shown.

`LlmService` has exactly one model-facing method: `generateSql()`. There is no `summarizeResults()` or results-lead-in generator anymore.

### Gemini API

| Item | Value |
|---|---|
| Provider | Google Gemini Developer API |
| Endpoint | `https://generativelanguage.googleapis.com/v1beta` (the free-tier REST endpoint — no billing account, no Google Cloud project setup required) |
| Model | `gemini-flash-lite-latest` — always resolves to the newest Flash-Lite model, the lowest-token-cost / highest-free-quota tier Gemini offers |
| Auth | Personal API key, entered once via `ApiKeyScreen`, stored on-device with `shared_preferences` |
| Requests per question | Exactly 1 per attempt (up to 3 with retries) |
| Internet after setup | **Required** — every question makes a live API call |

Get a free key at [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) — no credit card needed. The key is sent as the `x-goog-api-key` header on every request and never leaves the device except in that request.

**Why Flash-Lite?** SQL generation from a handful of pre-filtered tables is a short, structured, low-reasoning task — exactly what Flash-Lite is built for. It carries the most generous free-tier rate limits of any Gemini model, which matters directly since every question in this app is a live API call rather than a one-time download.

**Changing your key:** tap the key icon in the chat screen's top bar at any time to clear the stored key and re-enter a new one.

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
│   │   └── chat_message.dart          ← ChatMessage (includes selectedTableNames)
│   │
│   ├── schema/
│   │   └── agri_schema.dart           ← swappable schema definition
│   │
│   ├── services/
│   │   ├── db_service.dart            ← sqflite access, SQL validation, case-insensitive
│   │   │                                 rewrite, DB freshness/re-copy logic
│   │   ├── schema_selector.dart       ← keyword-scoring table selection
│   │   ├── sql_column_validator.dart  ← deterministic table/column/enum-value check
│   │   ├── join_path_finder.dart      ← BFS over the FK graph for join-path hints
│   │   ├── llm_service.dart           ← Gemini API key storage + SQL generation
│   │   │                                 (the only model-facing service — no
│   │   │                                 summarization here anymore)
│   │   └── query_service.dart         ← pipeline orchestrator + deterministic
│   │                                     answer assembly
│   │
│   └── ui/
│       ├── app_theme.dart             ← colors, typography, theme
│       ├── app_state.dart             ← ChangeNotifier, all app state
│       ├── screens/
│       │   ├── splash_screen.dart
│       │   ├── api_key_screen.dart    ← one-time Gemini API key entry
│       │   └── chat_screen.dart       ← clear/delete button disabled while a
│       │                                 response is generating; key icon to
│       │                                 change the stored API key
│       └── widgets/
│           ├── chat_bubble.dart       ← SQL disclosure + debug table panel
│           ├── input_bar.dart
│           ├── empty_chat.dart
│           ├── thinking_indicator.dart
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

### Token budget

Gemini's context window is far larger than this app will ever need, so there's no hard prompt-fitting limit to design around — but `SchemaSelector` still keeps only a handful of relevant tables in every request, since fewer input tokens means less of the free-tier's per-minute token budget consumed per question. You can safely have 100+ tables in the schema — only the relevant subset is ever sent to the model. `maxOutputTokens` is capped at 300 in `LlmService`, comfortably more than a generated SQL query needs, to keep each response small and fast.

---

## Security

- Only `SELECT` statements are allowed. `DROP`, `DELETE`, `UPDATE`, `INSERT`, `ALTER`, `CREATE`, `REPLACE`, `TRUNCATE`, `ATTACH`, `DETACH`, `PRAGMA` are all rejected.
- The database is opened and protected at the query validation layer via `validateSql()`.
- The Gemini API key is stored on-device via `shared_preferences` in plain text. This is fine for personal or single-user field use; if you're distributing this app to other people's devices, swap `shared_preferences` for `flutter_secure_storage` in `llm_service.dart`.
- Only the question text and the selected table/column names (never row data) are sent to Google as part of SQL generation. Query *results* never leave the device — the answer is assembled from local database rows in Dart.

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
  - **401 / `API_KEY_INVALID`** — the stored key is wrong or has been revoked. Tap the key icon in the chat screen to re-enter it.
  - **429 / `RESOURCE_EXHAUSTED`** — the free tier's requests-per-minute or requests-per-day limit was hit. Wait (RPM limits clear within a minute; RPD resets at midnight Pacific) or reduce request volume.
  - **Network error / timeout** — no internet connectivity, or the request exceeded `ApiConfig.requestTimeout` (30s).

### App can't reach Gemini at all
- Confirm the device has internet access — this is no longer an offline app.
- Confirm your API key was actually saved: clear it via the key icon and re-enter it.

---

## Known limitations

- **Requires internet for every question.** Unlike the original on-device design, each question is a live Gemini API call — there's no offline fallback.
- **Free-tier rate limits.** `gemini-flash-lite-latest` has the most generous free-tier limits Gemini offers, but they're still finite (requests-per-minute and requests-per-day caps, reset details vary by Google's current published limits). Heavy or bursty use can hit a 429 — see Troubleshooting above.
- **Repeated identical mistakes on retry.** The self-correction loop feeds back a specific, accurate error, but the model doesn't always act on it — occasionally it repeats the exact same wrong column/table name across all 3 attempts even when told precisely what the correct one is. `SqlColumnValidator` and `JoinPathFinder` measurably reduce how often this happens (especially for join-path reasoning), but don't eliminate it. Treat repeated "couldn't come up with a working query" failures on a specific question as a signal worth investigating via the debug log, not always a bug in the validation layer.
- **`IN (...)` lists aren't case-normalized or enum-checked.** Both `COLLATE NOCASE` rewriting and enum-value validation currently only cover direct `=`/`!=`/`<>` string comparisons.
- **Deterministic answers favor correctness over natural phrasing.** Since the answer text is built entirely in Dart rather than paraphrased by the model, multi-row answers read as a structured list ("Here's what I found — 5 in total: ...") rather than free-form prose. This was a deliberate trade after LLM-generated summaries proved unreliable — see "Deterministic answer assembly" above.

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `sqflite` | ^2.3.3 | SQLite access |
| `http` | ^1.2.2 | Gemini API requests |
| `path_provider` | ^2.1.3 | App documents directory |
| `provider` | ^6.1.2 | State management |
| `google_fonts` | ^6.3.3 | DM Sans |
| `flutter_markdown` | ^0.7.3 | Markdown rendering (bullet lists in answers) |
| `shared_preferences` | ^2.2.3 | Gemini API key storage, DB freshness tracking |
| `intl` | ^0.19.0 | Timestamp formatting |

All validation logic (`SqlColumnValidator`, `JoinPathFinder`) is plain Dart with no additional package dependencies.

---

## Credits

- LLM: [Gemini API](https://ai.google.dev/gemini-api/docs) by Google
