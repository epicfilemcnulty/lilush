# RELIW Current State and Remediation Plan

Date: 2026-02-06
Author: Codex review pass

## Status

- Current phase: `Phase 6` completed on `2026-02-06`.
- Next phase: `Phase 7: RELIW Documentation Completion`.
- Open blockers: none currently.

## Scope and Baseline

This document covers RELIW server/runtime paths and direct integration points:

- `src/reliw/reliw.lua`
- `src/reliw/reliw/*.lua`
- `src/luasocket/web_server.lua`
- Supporting helper behavior used by RELIW (`src/luasocket/web.lua`, `src/redis/redis.lua`)

Assumptions (confirmed):

- RELIW must degrade gracefully even without a perfect reverse proxy in front.
- Proxy entries with `scheme = "https"` are intended to make real TLS upstream connections.
- Redis failures should produce controlled 5xx behavior and not crash request workers.

## Current Findings (Severity-Ordered)

### High Severity

1. Unchecked Redis store creation can crash request workers. (Phase 1: fixed)
   - Evidence: `src/reliw/reliw/handle.lua:12` creates `store = store.new(srv_cfg)` and does not validate result before use at `src/reliw/reliw/handle.lua:22`.
   - Impact: transient Redis/network failure can turn into Lua runtime exceptions and worker exits.
   - Required fix: validate `store` and return controlled `503`/`500` response when initialization fails.

2. Metrics endpoint leaks Redis connections on every request. (Phase 1: fixed)
   - Evidence: `src/reliw/reliw/metrics.lua:3-10` opens `store`, returns from both success and 404 branches without `store:close()`.
   - Impact: connection/fd growth over time, especially under scraping.
   - Required fix: always close store in `metrics.show`, including error and non-`/metrics` paths.

3. Proxy uses `assert` on runtime network operations. (Phase 1: fixed)
   - Evidence: `src/reliw/reliw/proxy.lua:76` and `src/reliw/reliw/proxy.lua:84`.
   - Impact: upstream connect failures can crash request worker instead of returning `502`.
   - Required fix: replace `assert` with explicit error returns and controlled upstream close behavior.

4. HTTPS proxy targets are not using TLS. (Phase 2: fixed)
   - Evidence: prior behavior selected 443 for HTTPS but did not perform TLS wrap/handshake.
   - Impact: plaintext sent to TLS backends, failed proxying, security mismatch.
   - Required fix: wrap upstream TCP socket using `ssl.wrap` and handshake when `target.scheme == "https"`.

5. Chunked request bodies bypass configured max body size. (Phase 3: fixed)
   - Evidence: prior behavior enforced max size only for `Content-Length`, not cumulative chunked bodies.
   - Impact: memory exhaustion risk from unbounded chunked upload.
   - Required fix: enforce cumulative body-size limit while reading chunks; fail with `413`.

6. Host/query values can reach filesystem resolution without strict sanitization. (Phase 3: fixed)
   - Evidence: prior behavior trusted host/query-derived file paths without strict normalization and confinement checks.
   - Impact: path traversal and tenant-breakout risk if malformed host/query passes through.
   - Required fix: strict host validation and safe path canonicalization/join checks before reads.

### Medium Severity

7. RELIW manager reaps only one child path by blocking on IPv4 PID. (Phase 4: fixed)
   - Evidence: prior behavior blocked on `std.ps.wait(self.reliw_pid)` and did not reap non-primary exits.
   - Impact: non-IPv4 children (metrics/ipv6) can become zombies under restart/failure timing.
   - Required fix: reaping loop for all children until target shutdown condition is met.

8. Auth POST parser can error on empty/malformed request body. (Phase 6: fixed)
   - Evidence: prior behavior called `web.parse_args(body)` without guarding non-string body values.
   - Impact: malformed login requests can cause runtime error.
   - Required fix: guard nil/empty body in auth handler and parser entry points.

9. ETag conditional flow can emit `304` for non-GET/HEAD methods. (Phase 2: fixed)
   - Evidence: prior behavior allowed `If-None-Match` short-circuit on non-`GET` methods.
   - Impact: incorrect HTTP semantics for unsafe methods.
   - Required fix: apply `If-None-Match` shortcut only for `GET` and `HEAD`.

10. Proxy chunk parser does not support chunk extensions. (Phase 2: fixed)
    - Evidence: prior behavior used direct `tonumber(line, 16)` and rejected valid extension forms.
    - Impact: valid chunked responses using extensions fail to parse.
    - Required fix: parse leading hex token only (`^%s*([0-9A-Fa-f]+)`).

11. Metrics fetch uses Redis `KEYS`. (Phase 5: fixed)
    - Evidence: prior behavior used `KEYS <prefix>:METRICS:*:total` in metrics collection path.
    - Impact: blocking O(N) scan can degrade Redis under large keyspaces.
    - Required fix: replace with `SCAN`-based iteration or maintained index set.

## Test Coverage Gaps

Current state:

- Phase 1 introduced RELIW-targeted smoke tests under `tests/reliw/` for:
  - store initialization failure handling in request path
  - metrics connection close behavior and init-failure response
  - proxy socket/connect failure non-crashing behavior
- Phase 2 added protocol-correctness tests for:
  - HTTPS upstream TLS proxy behavior and chunk-extension parsing
  - ETag method semantics (`GET`/`HEAD`/non-`GET`)
- Phase 3 added hardening tests for:
  - chunked request body max-size enforcement
  - host/query validation and store path traversal blocking
- Phase 4 added lifecycle test coverage for:
  - manager any-child wait loop and sibling-drain reaping behavior
- Phase 6 added auth/parser hardening coverage for:
  - malformed login POST bodies and parser entry-point tolerance
- Full RELIW lifecycle/protocol/security coverage is still incomplete.

Missing test categories:

- none currently identified for the tracked RELIW remediation phases.

## Implementation Plan (Phased)

### Phase 1: Crash and Leak Containment (Immediate)

Objective: stop process crashes and connection leaks with minimal semantic changes.

Status: Completed on 2026-02-06.

Changes:

- `src/reliw/reliw/handle.lua`
  - Check result of `store.new`.
  - On failure, return deterministic 503 response with plain text and log error details.
- `src/reliw/reliw/metrics.lua`
  - Close store on every return path.
  - If `storage.new` fails, return controlled `503` and include cause in logs.
- `src/reliw/reliw/proxy.lua`
  - Replace `assert(socket.tcp())` and `assert(upstream:connect(...))` with checked branches.
  - Return `nil, <error>` without throwing.

Acceptance:

- Upstream failures produce 502 from caller path, not worker crash. (validated by new proxy failure test)
- `/metrics` repeated scraping does not increase open socket count over time. (validated by close-path test)

### Phase 2: Protocol Correctness

Objective: make proxying and conditional response behavior correct by HTTP/TLS semantics.

Changes:

- `src/reliw/reliw/proxy.lua`
  - Add TLS upstream mode:
    - `target.scheme == "https"` => wrap socket with `ssl.wrap`.
    - Set server-name/SNI from upstream host where applicable.
    - Perform handshake and return controlled errors on failure.
  - Parse chunked size lines with extension support (`hex-token` prefix parsing).
- `src/reliw/reliw/handle.lua`
  - Restrict ETag conditional short-circuit to `GET`/`HEAD` only.

Acceptance:

- HTTPS upstream endpoints proxy successfully.
- Chunked responses with extensions parse correctly.
- Non-GET/HEAD requests never return 304 from ETag shortcut.

Implementation details (planned):

1. Test-first scaffolding
   - Add `tests/reliw/test_proxy_https.lua` with stubs for `socket` and `ssl` to verify:
     - HTTPS targets call `ssl.wrap(...)` with client mode and upstream SNI.
     - Handshake failures return controlled errors and close sockets.
     - HTTP targets do not invoke TLS wrapping.
   - Extend proxy parser coverage (same file or split test) to validate chunk-size lines with extensions (for example `4;foo=bar`).
   - Add `tests/reliw/test_etag_method_semantics.lua` to verify:
     - `GET` + matching `If-None-Match` => `304`.
     - `HEAD` path stays bodyless and does not emit `304`.
     - non-`GET`/`HEAD` methods do not short-circuit to `304` when ETag matches.

2. Proxy TLS correctness (`src/reliw/reliw/proxy.lua`)
   - Require `ssl` and add a small helper for upstream connect flow:
     - create TCP socket
     - connect host/port
     - if `target.scheme == "https"`, wrap with `ssl.wrap` and run `:dohandshake()`
   - Preserve Phase 1 error behavior: return `nil, <message>` and close underlying sockets on every failure branch.
   - Keep timeout handling explicit for connect + handshake stages.

3. Chunked response parsing correctness (`src/reliw/reliw/proxy.lua`)
   - Change chunk-size parsing to consume only the leading hex token (`^%s*([0-9A-Fa-f]+)`), ignoring chunk extensions.
   - For zero-sized terminal chunk, consume trailer lines until the blank delimiter.
   - Keep existing body assembly behavior and downstream header normalization.

4. ETag semantics fix (`src/reliw/reliw/handle.lua`)
   - Gate conditional `304` shortcut behind method checks so only `GET`/`HEAD` participate.
   - Preserve current HEAD no-body behavior while ensuring unsafe methods (`POST`, `PUT`, etc.) continue normal processing even when ETag matches.

5. Validation and rollout gate
   - Run targeted tests:
     - `./lilush tests/reliw/test_proxy_https.lua`
     - `./lilush tests/reliw/test_etag_method_semantics.lua`
     - existing `tests/reliw/test_proxy_upstream_failure.lua` regression
   - Run full suite: `./run_all_tests.bash`.
   - Ship Phase 2 in a dedicated commit to keep rollback scope narrow.

TLS policy decision (resolved):

- Selected option: allow self-signed upstreams via proxy config knob (`tls_insecure = true` / `tls_no_verify = true` / `no_verify_mode = true`).
- Default remains verified TLS unless one of the explicit relax flags is set.

### Phase 3: Request-Body and Path Hardening

Objective: block easy resource abuse and path traversal vectors.

Status: Completed on 2026-02-06.

Changes:

- `src/luasocket/web_server.lua`
  - Add cumulative byte counter to `read_chunked_body`.
  - Reject chunked payload once `max_body_size` is exceeded with `413`.
- `src/reliw/reliw/handle.lua` and `src/reliw/reliw/store.lua`
  - Add strict host normalization/validation (compat-safe allowlist: domain, `localhost`, IPv4, bracketed IPv6).
  - Add safe path join/canonicalization check:
    - resolved path must remain under allowed roots (`data_dir/<host>` or fallback root).
  - Reject suspicious `query` forms early with 400.

Acceptance:

- Oversized chunked uploads are consistently rejected with 413.
- Traversal payloads (`..`, encoded traversal, malformed host) cannot escape content roots.

### Phase 4: Process Lifecycle Reliability

Objective: prevent zombie accumulation for non-primary child processes.

Status: Completed on 2026-02-06.

Changes:

- `src/reliw/reliw.lua`
  - Replace single `std.ps.wait(self.reliw_pid)` strategy with a manager reaping loop.
  - Track and reap all spawned child PIDs (`reliw_pid`, `reliw6_pid`, `metrics_pid`).
  - Define manager exit policy:
    - Exit when primary server process exits.
    - Drain any already-exited children before termination.

Implementation details (implemented):

1. Test-first scaffolding
   - Add `tests/reliw/test_manager_reaping.lua` with stubs for:
     - `std.ps.fork`, `std.ps.wait`, `std.ps.waitpid`
     - config/bootstrap dependencies (`std.fs`, `cjson.safe`, `web_server`, `reliw.store`)
   - Validate manager behavior with deterministic PID/event sequences:
     - non-primary child exits first (manager keeps running and continues waiting).
     - primary child exits (manager transitions to shutdown path).
     - drain step reaps remaining exited children via `waitpid(-1)` until no children are pending.
   - Add assertions that manager uses any-child wait semantics (no longer blocks only on IPv4 PID).

2. Manager child tracking (`src/reliw/reliw.lua`)
   - Introduce small helpers for:
     - collecting spawned child PIDs into a tracked table/set.
     - reaping one child result and removing it from tracked state.
     - non-blocking drain loop (`waitpid(-1)` until `<= 0`).
   - Keep existing spawn order and process naming unchanged to avoid startup behavior regressions.

3. Main reaping loop and exit policy (`src/reliw/reliw.lua`)
   - Replace `std.ps.wait(self.reliw_pid)` with a loop that blocks on any child exit (`wait(-1)`):
     - if exited PID is non-primary: mark reaped and continue loop.
     - if exited PID is primary (`reliw_pid`): break to shutdown path.
   - After primary exit, run drain loop to reap already-exited siblings (`reliw6_pid`, `metrics_pid`) before manager exits.
   - Preserve current behavior that manager does not actively kill sibling children in Phase 4; this phase is strictly zombie-prevention/reaping reliability.

4. Validation and rollout gate
   - Run targeted test:
     - `./lilush tests/reliw/test_manager_reaping.lua`
   - Run existing RELIW regression tests that touch startup/proxy paths:
     - `./lilush tests/reliw/test_proxy_upstream_failure.lua`
     - `./lilush tests/reliw/test_proxy_https.lua`
   - Run full suite:
     - `./run_all_tests.bash`
   - Ship Phase 4 as its own commit for low-risk rollback.

Acceptance:

- No persistent `<defunct>` RELIW children after repeated restarts and load tests.

### Phase 5: Metrics Scalability

Objective: remove Redis blocking operations from metrics path.

Status: Completed on 2026-02-06.

Changes:

- `src/reliw/reliw/store.lua`
  - Replace `KEYS` with cursor-based `SCAN` iteration for metrics key discovery.
  - Keep output format unchanged (`http_requests_total`, `http_requests_by_method`).
  - Add sane scan batch size default and upper bound per request to avoid long scrapes.

Implementation details (implemented):

1. SCAN-based metrics host discovery (`src/reliw/reliw/store.lua`)
   - Replaced `KEYS` lookup with cursor loop:
     - `SCAN <cursor> MATCH <prefix>:METRICS:*:total COUNT <scan_count>`
   - Added host deduplication and deterministic ordering before metrics emission.
   - Preserved output families and label names:
     - `http_requests_total{host=...,code=...}`
     - `http_requests_by_method{host=...,method=...}`

2. Bounded scrape controls (`src/reliw/reliw/store.lua`)
   - Added optional metrics config knobs:
     - `metrics.scan_count` (default `100`, clamped `1..1000`)
     - `metrics.scan_limit` (default `2000`, clamped `1..10000`)
   - Enforced per-scrape key upper bound to avoid unbounded Redis work.

3. Regression coverage (`tests/reliw/test_metrics_scan.lua`)
   - Added test to assert `SCAN` usage and verify no `KEYS` calls.
   - Added test for count/limit bounds and limit-enforced host truncation behavior.

4. Validation and rollout gate
   - `./lilush tests/reliw/test_metrics_scan.lua`
   - `./lilush tests/reliw/test_metrics_connection_close.lua`
   - `./run_all_tests.bash`

Acceptance:

- Metrics endpoint remains responsive on larger keyspaces without Redis latency spikes.

### Phase 6: RELIW Regression Test Suite

Objective: complete durable automated coverage for remaining RELIW risk paths.

Status: Completed on 2026-02-06.

Changes:

- Expand RELIW-focused tests under `tests/reliw/`:
  - (already done in Phase 1) `test_store_init_failure.lua`
  - (already done in Phase 1) `test_metrics_connection_close.lua`
  - (already done in Phase 1) `test_proxy_upstream_failure.lua`
  - add `test_proxy_https.lua`
  - `test_chunked_body_limits.lua`
  - `test_path_sanitization.lua`
  - `test_auth_malformed_body.lua`
  - `test_etag_method_semantics.lua`
  - `test_manager_reaping.lua`
- Add lightweight fixtures/mocks for Redis and upstream proxy behavior.
- Integrate new tests into `run_all_tests.bash` flow.

Implementation details (implemented):

1. Auth malformed-body hardening
   - `src/reliw/reliw/auth.lua`
     - Guarded login POST body input (`type(body) == "string"` fallback) before parse.
   - `src/luasocket/web.lua`
     - Hardened `parse_args` entry point to return empty args table for nil/non-string/empty bodies.

2. Regression coverage
   - Added `tests/reliw/test_auth_malformed_body.lua`:
     - verifies `web.parse_args` tolerates nil/non-string input and still parses valid form bodies.
     - verifies `auth.login_page` with malformed POST body returns deterministic `401` without throwing.

3. Default test-flow verification
   - Confirmed RELIW regression tests are included by default via `run_all_tests.bash` (`tests/**/*.lua` glob), including the new auth malformed-body test.

Acceptance:

- Tests fail on current buggy behaviors and pass after fixes.
- CI/local run includes RELIW suite by default.

### Phase 7: RELIW Documentation Completion

Objective: provide complete operator/developer documentation after remediation phases are finished.

Changes:

- Create detailed RELIW docs covering:
  - full configuration reference (core server, TLS, proxy, metrics, timeouts, and defaults).
  - Redis data model/schema used by RELIW:
    - key namespaces and value formats
    - required vs optional fields
    - proxy metadata schema
    - metrics and rate-limit keys
  - WAF behavior:
    - request evaluation flow
    - rule model and matching semantics
    - block behavior and logging expectations
  - request handling semantics:
    - auth flow
    - proxy routing behavior
    - ETag/cache behavior by method
    - failure-mode responses (4xx/5xx)
  - operational guidance:
    - rollout/rollback notes
    - observability (logs/metrics)
    - troubleshooting checklist for common failures.
- Update `src/reliw/README.md` to point to the full docs and keep quickstart examples aligned.
- Ensure docs reflect final behavior from Phases 1-6 and include tested examples.

Acceptance:

- RELIW has an end-to-end operator/developer guide with concrete examples.
- Configuration and Redis schema documentation are sufficient to deploy/operate without source-diving.
- WAF and proxy behavior are documented with expected outcomes and failure handling.

## API and Behavior Changes

Expected behavior changes after remediation:

- RELIW no longer crashes on store/proxy init faults; returns controlled 5xx/502.
- `/metrics` no longer leaks store connections.
- HTTPS upstream proxy routes perform real TLS handshakes.
- Chunked upload limits match `max_body_size` policy.
- ETag 304 logic applies only to GET/HEAD.
- Traversal/malformed host-query combinations are rejected safely.
- Manager reaps all child processes robustly.

No public configuration schema changes are required for core fixes. Optional additions can include scan batch tuning for metrics.

## Test Plan and Acceptance Criteria

Functional checks:

1. Redis offline during normal request:
   - Expected: controlled 503/500 response, worker continues serving later requests.
2. `/metrics` repeated scrape loop:
   - Expected: stable fd count, no connection growth.
3. Proxy to dead upstream:
   - Expected: 502 response, no worker crash.
4. Proxy to HTTPS upstream:
   - Expected: successful TLS handshake and proxied content.
5. Large chunked upload:
   - Expected: 413 once cumulative size crosses cap.
6. Traversal attempts:
   - Expected: 400/404 safe failure; no outside-root file reads.
7. Empty/malformed login POST:
   - Expected: deterministic auth failure response; no Lua runtime error.
8. ETag with POST/PUT:
   - Expected: no 304 shortcut.
9. Repeated spawn/exit cycles:
   - Expected: no lingering zombies.
10. Large metrics keyspace:
    - Expected: no blocking Redis `KEYS` spikes.

Operational checks:

- Continue using `test_reliw_close.sh`/`full_test.bash` for connection lifecycle regression.
- Monitor `CLOSE_WAIT`, zombie counts, and worker crash frequency after deployment.

## Rollout and Verification

Recommended rollout order:

1. Deploy Phase 1 and Phase 2 together (stability + correctness core).
2. Run soak tests on low-traffic node.
3. Deploy Phase 3 and Phase 4 (hardening + lifecycle).
4. Deploy Phase 5 metrics scaling improvement.
5. Gate final rollout on Phase 6 regression tests in default test run.
6. Complete Phase 7 documentation pass once behavior is stabilized.

Rollback guidance:

- Keep fixes grouped by phase in separate commits for surgical revert.
- Prefer rolling back only the most recent phase if regressions appear.

## Assumptions and Defaults

- Fail closed on suspicious host/query/path input.
- Prefer explicit error-return paths instead of `assert`.
- Keep Linux-only behavior aligned with project constraints.
- Preserve existing config compatibility unless new optional knobs are introduced.
- Prioritize runtime stability and predictable failure modes over legacy undefined behavior.

## Progress Log

### 2026-02-06 — Phase 6 Implemented

Status: Completed.

Implemented fixes:

- `src/reliw/reliw/auth.lua`
  - Added malformed-body guard in login POST path so non-string bodies no longer trigger parser errors.
- `src/luasocket/web.lua`
  - Hardened `parse_args` to return empty args for nil/non-string/empty bodies.
- `tests/reliw/test_auth_malformed_body.lua`
  - Added regression coverage for parser tolerance and deterministic `401` auth behavior on malformed POST body.

Validation completed:

- `./lilush tests/reliw/test_auth_malformed_body.lua` passed.
- `./run_all_tests.bash` passed.

### 2026-02-06 — Phase 5 Implemented

Status: Completed.

Implemented fixes:

- `src/reliw/reliw/store.lua`
  - Replaced metrics key discovery from blocking `KEYS` to cursor-driven `SCAN`.
  - Added bounded scrape controls via metrics config:
    - `scan_count` default/clamp: `100` / `1..1000`
    - `scan_limit` default/clamp: `2000` / `1..10000`
  - Preserved metrics output contract (`http_requests_total`, `http_requests_by_method`).
- `tests/reliw/test_metrics_scan.lua`
  - Added SCAN-path coverage with multi-cursor discovery and output checks.
  - Added bounds/limit behavior coverage and assertion that `KEYS` is no longer used.

Validation completed:

- `./lilush tests/reliw/test_metrics_scan.lua` passed.
- `./lilush tests/reliw/test_metrics_connection_close.lua` passed.
- `./run_all_tests.bash` passed.

### 2026-02-06 — Phase 4 Implemented

Status: Completed.

Implemented fixes:

- `src/reliw/reliw.lua`
  - Added manager-side child PID tracking for `metrics`, `server_ipv4`, and `server_ipv6`.
  - Replaced single-PID blocking wait with any-child wait loop (`std.ps.wait(-1)`), continuing until primary IPv4 worker exits.
  - Added non-blocking drain pass (`std.ps.waitpid(-1)`) after primary exit to reap already-exited sibling children.
- `tests/reliw/test_manager_reaping.lua`
  - Added deterministic manager lifecycle coverage with stubs for `std.ps.fork`, `std.ps.wait`, and `std.ps.waitpid`.
  - Validated non-primary-first exit behavior, primary-exit shutdown transition, and sibling drain reaping.

Validation completed:

- `./lilush tests/reliw/test_manager_reaping.lua` passed.
- `./lilush tests/reliw/test_proxy_upstream_failure.lua` passed.
- `./lilush tests/reliw/test_proxy_https.lua` passed.
- `./run_all_tests.bash` passed.

### 2026-02-06 — Phase 3 Implemented

Status: Completed.

Implemented fixes:

- `src/luasocket/web_server.lua`
  - Added cumulative chunked-body byte tracking in `read_chunked_body`.
  - Enforced `max_body_size` for chunked requests and mapped violations to `413`.
  - Kept timeout and non-size parse error behavior controlled.
- `src/reliw/reliw/handle.lua`
  - Added strict host normalization/validation with explicit `400` on malformed host headers.
  - Added strict query validation (control chars, encoded traversal/separator forms, decoded `..` traversal) with explicit `400`.
  - Validation now happens before WAF/proxy/content flow.
- `src/reliw/reliw/store.lua`
  - Added path normalization helpers for file resolution.
  - Added safe storage path building for both `data_dir/<host>` and `data_dir/__` roots.
  - Rejects traversal/suspicious paths before file reads.
- `tests/reliw/test_chunked_body_limits.lua`
  - Added coverage for chunked payload max-size rejection (`413`) and within-limit success.
- `tests/reliw/test_path_sanitization.lua`
  - Added coverage for malformed host rejection, suspicious query rejection, and store-level traversal blocking.

Validation completed:

- `./lilush tests/reliw/test_chunked_body_limits.lua` passed.
- `./lilush tests/reliw/test_path_sanitization.lua` passed.
- Existing RELIW regressions (`test_store_init_failure`, `test_metrics_connection_close`, `test_proxy_upstream_failure`, `test_proxy_https`, `test_etag_method_semantics`) all passed.
- `./run_all_tests.bash` passed.

### 2026-02-06 — Phase 2 Implemented

Status: Completed.

Implemented fixes:

- `src/reliw/reliw/proxy.lua`
  - Added HTTPS upstream TLS mode via `ssl.wrap(...)` + handshake.
  - Added support for relaxed verification flags for self-signed/internal upstreams (`tls_insecure`/`tls_no_verify`/`no_verify_mode`).
  - Preserved controlled error returns and close-on-failure behavior.
  - Updated chunk parser to accept chunk extensions and to consume trailer lines correctly.
- `src/reliw/reliw/handle.lua`
  - Restricted ETag `304` shortcut to `GET` only; kept HEAD bodyless behavior without returning `304`.
  - Passed proxy TLS options from proxy metadata into proxy target.
- `tests/reliw/test_proxy_https.lua`
  - Added coverage for HTTPS TLS flow, handshake failure handling, plain HTTP no-wrap behavior, and chunk extension parsing.
- `tests/reliw/test_etag_method_semantics.lua`
  - Added coverage for `GET`/`HEAD`/`POST` ETag semantics.
- `tests/reliw/test_proxy_upstream_failure.lua`
  - Added `ssl` stub for isolation after TLS support changes.

Validation completed:

- `./lilush tests/reliw/test_proxy_upstream_failure.lua` passed.
- `./lilush tests/reliw/test_proxy_https.lua` passed.
- `./lilush tests/reliw/test_etag_method_semantics.lua` passed.
- `./run_all_tests.bash` passed.

### 2026-02-06 — Phase 1 Implemented

Status: Completed.

Implemented fixes:

- `src/reliw/reliw/handle.lua`
  - Added guarded `storage.new(...)` initialization.
  - On store init failure, returns controlled `503` with `text/plain` body.
  - Logs store initialization errors with request context.
- `src/reliw/reliw/metrics.lua`
  - Added `store:close()` on all success/non-success return paths.
  - Changed metrics store init failure response from `501` to `503`.
  - Added error logging on store init failure.
- `src/reliw/reliw/proxy.lua`
  - Replaced runtime `assert` on socket creation/connect with explicit error branches.
  - Returns `nil, <error>` instead of throwing.
  - Closes upstream socket on connect failure.

Tests added:

- `tests/reliw/test_store_init_failure.lua`
- `tests/reliw/test_metrics_connection_close.lua`
- `tests/reliw/test_proxy_upstream_failure.lua`
- `tests/reliw/_helpers.lua` (test helper for source-loading RELIW modules)

Validation completed:

- `./lilush tests/reliw/test_store_init_failure.lua` passed.
- `./lilush tests/reliw/test_metrics_connection_close.lua` passed.
- `./lilush tests/reliw/test_proxy_upstream_failure.lua` passed.
- `./run_all_tests.bash` passed with RELIW tests included.

Packaging/testing note:

- RELIW modules are not bundled into `lilush`; they are bundled into the standalone `reliw` app.
- RELIW tests were adapted to run under `./lilush` by source-loading RELIW modules from `src/reliw/reliw/*.lua` via `package.preload` + `dofile`.
