# Codex subscription and usage implementation notes (for Orchid)

This note captures how Codex models ChatGPT subscription, rate limits, credits, and token usage so Orchid can implement a compatible flow later.

## 1) Data model used by Codex

Codex uses a snapshot model that combines token usage plus account usage limits:

- `TokenUsage`:
  - `input_tokens`
  - `cached_input_tokens`
  - `output_tokens`
  - `reasoning_output_tokens`
  - `total_tokens`
- `TokenUsageInfo`:
  - `total_token_usage` (running total)
  - `last_token_usage` (latest turn)
  - `model_context_window` (optional integer)
- `RateLimitSnapshot`:
  - `limit_id` (e.g. `codex`, `codex_other`)
  - `limit_name` (optional user-facing label)
  - `primary` and `secondary` windows (`used_percent`, `window_minutes`, `resets_at`)
  - `credits` (`has_credits`, `unlimited`, `balance`)
  - `plan_type`

Reference:
- `/home/sdancer/projects/codex/codex-rs/protocol/src/protocol.rs` (lines ~1582-1695)

## 2) Subscription plan source

Codex extracts account plan from ChatGPT auth token claims (`chatgpt_plan_type`) and maps to normalized enum values (Free, Go, Plus, Pro, Team, Business, Enterprise, Edu, Unknown).

Reference:
- `/home/sdancer/projects/codex/codex-rs/core/src/token_data.rs` (lines ~23-90)
- `/home/sdancer/projects/codex/codex-rs/core/src/auth.rs` (lines ~265-292)

## 3) Usage endpoint polling pattern

Codex fetches usage from backend endpoints:

- Codex API path style: `GET /api/codex/usage`
- ChatGPT backend path style: `GET /wham/usage`

It requests usage snapshots every 60 seconds when ChatGPT auth is active, then publishes each snapshot into app state.

Reference:
- `/home/sdancer/projects/codex/codex-rs/backend-client/src/client.rs` (lines ~169-178)
- `/home/sdancer/projects/codex/codex-rs/tui/src/chatwidget.rs` (lines ~5554-5566, ~8710-8723)

## 4) Mapping payload to normalized snapshots

Codex converts backend payload (`RateLimitStatusPayload`) into:

- one base `codex` snapshot (with credits + plan),
- plus `additional_rate_limits` snapshots (per metered feature).

Important mapping details:
- `limit_window_seconds` -> `window_minutes` via rounded-up division.
- `reset_at` is stored as unix timestamp seconds.
- `credits` is attached only where backend provides it.

Reference:
- `/home/sdancer/projects/codex/codex-rs/backend-client/src/client.rs` (lines ~304-403)

## 5) Header/event parsing fallback

Codex also parses rate limit data from headers/events:

- Header families like `x-codex-primary-used-percent`, and for extra buckets `x-<limit>-...`
- Credits headers:
  - `x-codex-credits-has-credits`
  - `x-codex-credits-unlimited`
  - `x-codex-credits-balance`
- Event payload type: `codex.rate_limits`

Reference:
- `/home/sdancer/projects/codex/codex-rs/codex-api/src/rate_limits.rs` (lines ~21-215)

## 6) Merge semantics (critical)

Codex explicitly keeps prior values when a new snapshot omits them:

- if `limit_id` missing -> default `"codex"`
- if `credits` missing -> reuse previous credits
- if `plan_type` missing -> reuse previous plan

This avoids UI flicker and information loss from partial backend snapshots.

Reference:
- `/home/sdancer/projects/codex/codex-rs/core/src/state/session.rs` (lines ~241-258)
- `/home/sdancer/projects/codex/codex-rs/tui/src/chatwidget.rs` (lines ~1769-1851)

## 7) 429 semantics and hard-limit handling

On HTTP 429, Codex distinguishes:

- `usage_limit_reached` -> maps to a structured usage-limit error with:
  - `plan_type`
  - optional `resets_at`
  - parsed rate limit snapshot from headers
  - optional promo message (`x-codex-promo-message`)
- `usage_not_included` -> maps to a separate non-retryable error
- otherwise -> generic retry-limit handling

Reference:
- `/home/sdancer/projects/codex/codex-rs/core/src/api_bridge.rs` (lines ~67-93)

## 8) UX policies worth copying into Orchid

- Persist and display both context usage and account usage (different resources).
- Only nudge model switching when usage percentage is high and user has not hidden prompt.
- Maintain a stale threshold for display snapshots (Codex uses 15 minutes).
- Surface a link to canonical account usage settings page for authoritative numbers.

Reference:
- `/home/sdancer/projects/codex/codex-rs/tui/src/chatwidget.rs` (lines ~1814-1835, ~5591-5688)
- `/home/sdancer/projects/codex/codex-rs/tui/src/status/rate_limits.rs` (`RATE_LIMIT_STALE_THRESHOLD_MINUTES = 15`)
- `/home/sdancer/projects/codex/codex-rs/tui/src/status/card.rs` (lines ~475-484)

## 9) Suggested Orchid integration shape (Elixir)

Recommended components:

- `Orchid.Usage.Snapshot` schema
  - `limit_id`, `limit_name`
  - `primary_used_percent`, `primary_window_minutes`, `primary_resets_at`
  - `secondary_used_percent`, `secondary_window_minutes`, `secondary_resets_at`
  - `credits_has_credits`, `credits_unlimited`, `credits_balance`
  - `plan_type`
  - `captured_at`
- `Orchid.Usage.TokenUsage` schema
  - same fields as Codex `TokenUsage` + `model_context_window`
- `Orchid.Usage.Poller` (GenServer, every 60s)
  - only active for ChatGPT-auth sessions
  - fetch usage endpoint, normalize payload, merge partial snapshots
- `Orchid.Usage.Merge.merge(old, new)`
  - implement Codex carry-forward semantics for missing `credits` and `plan_type`
- `Orchid.Usage.Errors.from_http_response/1`
  - detect `usage_limit_reached`, `usage_not_included`
  - parse reset timestamp and rate-limit headers where available

## 10) Immediate implementation checklist in Orchid

- Add protocol structs/types for token usage + rate limits.
- Add usage fetch client (`/api/codex/usage` or equivalent backend route).
- Add snapshot merge logic preserving missing fields.
- Add periodic refresh (60s) and on-demand refresh after each turn.
- Add explicit 429 sub-type handling for usage-limit vs generic retry.
- Add status UI section for credits/limits with stale indicator.
