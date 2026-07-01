# Design: traject-solr_pool pooled Solr JSON writer

- Date: 2026-07-01
- Status: Approved (design phase)
- Scope: A traject writer that routes Solr updates through a persistent,
  pooled, thread-safe HTTP client provided by `http_connection_pool`, with a
  reusable connection seam for a future reader.

## Goal

Provide `Traject::SolrPool::SolrJsonWriter`, a drop-in replacement for
`Traject::SolrJsonWriter` that sends every Solr HTTP call over a persistent,
credential-isolated connection pool (from the sibling `http_connection_pool`
gem) instead of opening a fresh `HTTPClient` connection per request.

The pooling logic is **not** reimplemented here. This gem is the traject-facing
adapter. It must:

- register via traject's `writer_class_name` setting,
- honour the existing `solr.*` / `solr_writer.*` settings surface so it is a
  drop-in wherever practical,
- route every HTTP call through an `http_connection_pool` pool keyed by the
  Solr origin,
- be thread-safe and usable from Sidekiq >= 8 workers, and coexist cleanly with
  Zeitwerk and Rails (verified by tests; no Rails runtime dependency).

A reader is **future scope**: the connection unit is designed so a reader can
reuse it later, but no reader is built now.

## Non-goals

- Reimplementing connection pooling, keep-alive, or socket handling.
- A new settings vocabulary. Reuse `solr.*` / `solr_writer.*`; new settings are
  namespaced under `solr_pool.*` and documented.
- Building the reader.
- JRuby support (not verified).

## Architecture

Two units, split along the boundary the future reader will reuse. The reader
shares the **connection**, not the batching/threading — so the reusable seam is
drawn around the connection.

### Unit A — `Traject::SolrPool::Connection` (reusable)

Owns everything `http_connection_pool`-related. Constructed once from
`settings` inside the writer's `initialize`.

Responsibilities:

- Derive the **origin** (`scheme://host:port`) from the resolved Solr update
  URL. The origin becomes the pool `base_url`; the remainder of the URL becomes
  the relative request path used per request.
- Build `pool_options` from settings: a JSON content-type header, a Basic-auth
  header when credentials are present, and timeout options. Credentials live in
  headers (never baked into the origin), so distinct credentials resolve to
  distinct pool digests and never share connections.
- Bind to the pool using `http_connection_pool`'s documented `extend` path:
  create a small adapter object and `adapter.extend(HttpConnectionPool::Connectable)`,
  then set `base_url`, `pool_size`, `pool_timeout`, and `pool_options` from
  settings. Pool sharing and credential isolation are enforced by the
  `Registry` digest, not by class-level state, so per-instance runtime config is
  correct: same origin + same auth share one pool; different auth get separate
  pools.

Public API:

- `post_json(path, json_string)` — `with_connection { |conn| conn.post(path, body: json_string) }`, returns the http.rb response.
- `get(path, params:)` — `with_connection { |conn| conn.get(path, params: params) }`, returns the http.rb response.
- Readers exposing the derived origin and the relative update path base so the
  writer can build request paths and query strings.

Transport errors are surfaced at this boundary for the writer to classify (see
Error handling).

### Unit B — `Traject::SolrPool::SolrJsonWriter` (the writer)

A fresh port of the stock writer's **structure**, owning all traject-specific
concerns and delegating **all** HTTP to Unit A. Registered via
`writer_class_name: 'Traject::SolrPool::SolrJsonWriter'`.

Ported from the stock writer (structure reused, not subclassed — subclassing
would couple us to the parent's private methods and `HTTPClient`-specific
exception types):

- batched `Queue` and `Traject::ThreadPool`,
- `Concurrent::AtomicFixnum` skipped-record counter,
- `put`, `flush`, `send_batch`, `send_single`, `close`,
- `commit`, `delete`, `delete_all!`, `skipped_record_count`,
- settings/URL interpretation and credential stripping from logs.

HTTP calls (`@http_client.post/get`) are replaced with `connection.post_json` /
`connection.get`.

### Data flow

```
put(context)
  -> batched_queue << context
  -> when queue >= batch_size: thread_pool runs send_batch(batch)
       -> JSON.generate(batch docs)
       -> connection.post_json(update_path_with_query, json)
            -> Registry pool: borrow HTTP::Session, POST, return session
       -> on failure: retry each doc via send_single (per-record skip logic)
close
  -> flush remaining batch (via thread pool)
  -> shutdown_and_wait on thread pool
  -> commit if commit_on_close
  -> LEAVE POOL WARM (no Registry.release)
```

## Settings

Existing vocabulary, reused unchanged (drop-in):

| Setting | Role | Notes |
| --- | --- | --- |
| `solr.url` / `solr.update_url` | Origin + update path | Same derivation as stock: derive `/update/json` from `solr.url` when `update_url` unset. Origin becomes pool `base_url`; remainder becomes the relative request path. |
| `solr_writer.batch_size` | Batch size | Default 100 |
| `solr_writer.thread_pool` | Writer threads | Default 1 |
| `solr_writer.max_skipped` | Skip tolerance | Same semantics |
| `solr_writer.skippable_exceptions` | Custom skip list | Honoured if set; default list is http.rb-native (see Error handling) |
| `solr_writer.commit_on_close` | Commit at close | Same (incl. legacy `solrj_writer.commit_on_close`) |
| `solr_writer.solr_update_args` | Update query params | Same |
| `solr_writer.commit_solr_update_args` | Commit query params | Same |
| `solr_writer.http_timeout` | Request timeout | Fed into `pool_options` / applied per request via the http.rb chainable |
| `solr_writer.commit_timeout` | Commit timeout | Same intent, applied to the commit request |
| `solr_writer.basic_auth_user` / `solr_writer.basic_auth_password` | Auth | Same precedence; also parsed from embedded URI creds and stripped before logging |

New, namespaced:

| Setting | Default | Role |
| --- | --- | --- |
| `solr_pool.pool_size` | `solr_writer.thread_pool` + caller-thread headroom | Pool capacity, sized so no writer thread starves on checkout while the caller thread can still flush/commit |

Deliberately dropped (HTTPClient-specific; documented as removed/no-op):

- `solr_json_writer.http_client` — replaced by the pool; tests inject behaviour
  via WebMock instead of a client object.
- `solr_json_writer.use_packaged_certs` — an `HTTPClient` ssl_config quirk;
  http.rb uses OS certs.

## Error handling

- **`BadHttpResponse` preserved** for parity:
  `Traject::SolrPool::SolrJsonWriter::BadHttpResponse < RuntimeError`, raised on
  any non-200. Keeps its `#response` accessor and JSON `error.msg` extraction,
  but reads from an http.rb response (`response.code`, `response.to_s`). The
  `#response` object is now an http.rb response; documented as such.
- **Default `skippable_exceptions` becomes http.rb-native**, mapping transport
  failures so `max_skipped` logic still works:

  ```ruby
  [
    HTTP::TimeoutError,               # http.rb read/connect timeout
    HttpConnectionPool::TimeoutError, # pool checkout exhausted within pool_timeout
    HTTP::ConnectionError,            # http.rb transport failure (refused/reset)
    SocketError,
    Errno::ECONNREFUSED,
    Traject::SolrPool::SolrJsonWriter::BadHttpResponse
  ]
  ```

  Exact http.rb error constant names are confirmed against the installed gem
  during implementation (TDD catches a wrong constant immediately); the mapping
  intent above is authoritative.
- A user who sets `solr_writer.skippable_exceptions` explicitly gets exactly
  their list (unchanged behaviour).
- Pool checkout timeout (`HttpConnectionPool::TimeoutError`) is skippable: under
  a saturated pool a batch is skipped / retried individually rather than
  aborting the run, matching how timeouts behave today.
- `commit` and `delete` raise raw on failure (as the stock writer does — not
  part of the skip path).
- Credentials never appear in any log or error message: auth lives in headers,
  logs show origin only.

## Thread safety, Sidekiq, Zeitwerk, Rails

- **Thread safety** is mandatory. Shared state uses `concurrent-ruby`
  primitives (`Concurrent::AtomicFixnum` counter, `Queue`) as the stock writer
  does; no coarse global `Mutex` on the hot path. Connection checkout/return is
  owned entirely by `http_connection_pool`; a borrowed connection is never held
  across threads.
- **Sidekiq >= 8**: the writer must work inside a worker — instances created and
  torn down per job, many threads concurrent, process forks. Fork-safety is
  inherited from `connection_pool >= 2.5` (`auto_reload_after_fork`); this gem
  caches no raw sockets or connection objects across a fork.
- **Zeitwerk / Rails**: file/constant layout stays Zeitwerk-conformant so a host
  app's loader is happy, even though traject loads via plain `require`. No Rails
  runtime dependency — Rails/Zeitwerk/Sidekiq are test-only.

## Testing strategy (TDD, WebMock)

Unit specs (fast, no live Solr) drive **real http.rb through the real pool**,
with **WebMock** intercepting responses:

- `Connection`: origin derivation, `pool_options` / auth-header construction,
  credential isolation (different auth => different pool digest), relative-path
  requests resolve against the origin.
- `SolrJsonWriter`: `put` batching at `batch_size`; `send_batch` posts one JSON
  array; batch failure falls back to per-record `send_single`;
  `max_skipped` / skip-counter behaviour; `commit` / `delete` / `delete_all!`;
  URL derivation; credential stripping from logs; the `solr_pool.pool_size`
  default.
- Error mapping: WebMock simulates timeouts / 500s / connection-refused; assert
  skippable behaviour and `BadHttpResponse` with its `error.msg`.

Integration specs (tagged, slower):

- **Concurrency**: `solr_writer.thread_pool > 1` sending many batches through the
  pool; assert no lost/corrupted records and no checkout starvation. Barrier
  helper lives in a `spec/support` module included by tag.
- **Sidekiq >= 8 / fork**: writer used from a job-like context across a fork;
  assert fork-safety (fresh connections, no shared sockets).
- **Zeitwerk / Rails**: clean-subprocess eager-load proving Zeitwerk
  conformance; a Rails-style service-object coexistence check.

Conventions (from `CLAUDE.md`): single-quoted non-interpolated strings; no
apostrophes in example descriptions; `after do` teardown; reset
`HttpConnectionPool::Registry` between examples so pools never leak;
`spec/support/**` auto-required.

## Dependencies

Runtime (gemspec):

- `http_connection_pool` `~> 0.1`
- `traject` — currently via a **temporary** Gemfile `path:` override to an edge
  checkout (the last released traject caps `http < 6`, colliding with
  `http_connection_pool`'s `http ~> 6.0`; edge relaxes to `http >= 3.0, < 7`).
  The gemspec constraint is switched to the real released version once traject
  ships the relaxed cap; then the `path:` override is removed.

Test-only (a `:test` Gemfile group, nothing in `:development`):

- `webmock` — HTTP interception
- `activesupport` — Rails-coexistence checks (specific module, not full `rails`)
- `activejob` — Sidekiq-style job harness
- `zeitwerk` — standalone loader for the eager-load compliance spec (separate
  gem from activesupport; required directly)
- `sidekiq` — exercise the writer inside a real Sidekiq >= 8 worker context

`rails` is intentionally not pulled in; `activesupport` + `activejob` cover the
coexistence and job-integration cases. If a spec later genuinely needs Action
Pack or Railties, that is flagged rather than added silently.

## File / constant layout

```
lib/
  traject/solr_pool.rb                 # entry point (requires the pieces)
  traject/solr_pool/
    version.rb                         # Traject::SolrPool::VERSION
    connection.rb                      # Traject::SolrPool::Connection
    solr_json_writer.rb                # Traject::SolrPool::SolrJsonWriter
```

Layout stays Zeitwerk-conformant (file path matches constant name).

## Open items deferred to the plan

- Exact http.rb error constant names, verified against the installed gem.
- Precise `pool_size` headroom value (thread_pool + 1 vs a small constant).
- Whether `commit_timeout` maps to a per-request http.rb read-timeout override
  or a distinct pool option.
