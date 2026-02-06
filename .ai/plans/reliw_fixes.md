# RELIW Current State and Remediation Plan

Date: 2026-02-06
Author: Codex review pass

## Status

- Current phase: `Phase 1` completed on `2026-02-06`.
- Next phase: `Phase 2: Protocol Correctness`.
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

4. HTTPS proxy targets are not using TLS.
   - Evidence: `src/reliw/reliw/proxy.lua:80` chooses 443 for HTTPS, but no SSL wrap/handshake occurs in `src/reliw/reliw/proxy.lua:75-140`.
   - Impact: plaintext sent to TLS backends, failed proxying, security mismatch.
   - Required fix: wrap upstream TCP socket using `ssl.wrap` and handshake when `target.scheme == "https"`.

5. Chunked request bodies bypass configured max body size.
   - Evidence: chunked path uses `read_chunked_body` in `src/luasocket/web_server.lua:20-58` and `src/luasocket/web_server.lua:147-156`; max size check only exists for `Content-Length` in `src/luasocket/web_server.lua:163-167`.
   - Impact: memory exhaustion risk from unbounded chunked upload.
   - Required fix: enforce cumulative body-size limit while reading chunks; fail with `413`.

6. Host/query values can reach filesystem resolution without strict sanitization.
   - Evidence: host extraction in `src/reliw/reliw/handle.lua:15-20`; file resolution in `src/reliw/reliw/store.lua:79-125`.
   - Impact: path traversal and tenant-breakout risk if malformed host/query passes through.
   - Required fix: strict host validation and safe path canonicalization/join checks before reads.

### Medium Severity

7. RELIW manager reaps only one child path by blocking on IPv4 PID.
   - Evidence: `src/reliw/reliw.lua:129-131`.
   - Impact: non-IPv4 children (metrics/ipv6) can become zombies under restart/failure timing.
   - Required fix: reaping loop for all children until target shutdown condition is met.

8. Auth POST parser can error on empty/malformed request body.
   - Evidence: `src/reliw/reliw/auth.lua:86` calls `web.parse_args(body)`; parser assumes non-nil body at `src/luasocket/web.lua:486-489`.
   - Impact: malformed login requests can cause runtime error.
   - Required fix: guard nil/empty body in auth handler and parser entry points.

9. ETag conditional flow can emit `304` for non-GET/HEAD methods.
   - Evidence: `src/reliw/reliw/handle.lua:169-173`.
   - Impact: incorrect HTTP semantics for unsafe methods.
   - Required fix: apply `If-None-Match` shortcut only for `GET` and `HEAD`.

10. Proxy chunk parser does not support chunk extensions.
    - Evidence: `tonumber(line, 16)` in `src/reliw/reliw/proxy.lua:12`.
    - Impact: valid chunked responses using extensions fail to parse.
    - Required fix: parse leading hex token only (`^%s*([0-9A-Fa-f]+)`).

11. Metrics fetch uses Redis `KEYS`.
    - Evidence: `src/reliw/reliw/store.lua:293`.
    - Impact: blocking O(N) scan can degrade Redis under large keyspaces.
    - Required fix: replace with `SCAN`-based iteration or maintained index set.

## Test Coverage Gaps

Current state:

- Phase 1 introduced RELIW-targeted smoke tests under `tests/reliw/` for:
  - store initialization failure handling in request path
  - metrics connection close behavior and init-failure response
  - proxy socket/connect failure non-crashing behavior
- Full RELIW lifecycle/protocol/security coverage is still incomplete.

Missing test categories:

- Proxy `https` TLS behavior.
- Chunked request size limits and parser edge cases.
- Host/query path sanitization and traversal attempts.
- Auth malformed body handling.
- ETag method semantics.
- Manager/worker zombie reaping behavior.
- Metrics scalability path (`SCAN` vs `KEYS`) and connection close behavior.

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

### Phase 3: Request-Body and Path Hardening

Objective: block easy resource abuse and path traversal vectors.

Changes:

- `src/luasocket/web_server.lua`
  - Add cumulative byte counter to `read_chunked_body`.
  - Reject chunked payload once `max_body_size` is exceeded with `413`.
- `src/reliw/reliw/handle.lua` and `src/reliw/reliw/store.lua`
  - Add strict host normalization/validation (allow domain + IPv6 host forms only).
  - Add safe path join/canonicalization check:
    - resolved path must remain under allowed roots (`data_dir/<host>` or fallback root).
  - Reject suspicious `query` forms early with 400.

Acceptance:

- Oversized chunked uploads are consistently rejected with 413.
- Traversal payloads (`..`, encoded traversal, malformed host) cannot escape content roots.

### Phase 4: Process Lifecycle Reliability

Objective: prevent zombie accumulation for non-primary child processes.

Changes:

- `src/reliw/reliw.lua`
  - Replace single `std.ps.wait(self.reliw_pid)` strategy with a manager reaping loop.
  - Track and reap all spawned child PIDs (`reliw_pid`, `reliw6_pid`, `metrics_pid`).
  - Define manager exit policy:
    - Exit when primary server process exits.
    - Drain any already-exited children before termination.

Acceptance:

- No persistent `<defunct>` RELIW children after repeated restarts and load tests.

### Phase 5: Metrics Scalability

Objective: remove Redis blocking operations from metrics path.

Changes:

- `src/reliw/reliw/store.lua`
  - Replace `KEYS` with cursor-based `SCAN` iteration for metrics key discovery.
  - Keep output format unchanged (`http_requests_total`, `http_requests_by_method`).
  - Add sane scan batch size default and upper bound per request to avoid long scrapes.

Acceptance:

- Metrics endpoint remains responsive on larger keyspaces without Redis latency spikes.

### Phase 6: RELIW Regression Test Suite

Objective: complete durable automated coverage for remaining RELIW risk paths.

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

Acceptance:

- Tests fail on current buggy behaviors and pass after fixes.
- CI/local run includes RELIW suite by default.

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
