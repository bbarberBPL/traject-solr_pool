# CLAUDE.md — traject-solr_pool

## Project Goal

This gem is a **plugin for [traject](https://github.com/traject/traject)** that
lets traject writers (and future readers) send Solr/HTTP traffic over a
**persistent, pooled, thread-safe, Fiber-scheduler-aware HTTP client** instead
of opening a fresh connection per request.

The pooling itself is **not** reimplemented here. It is provided by the
`http_connection_pool` gem (a sibling project), which keeps one pool of
persistent `HTTP::Session` connections per origin, credential-isolated and safe
under heavy concurrency. This gem is the **traject-facing adapter**: it exposes
a writer (initially a drop-in replacement for `Traject::SolrJsonWriter`) that
speaks traject's writer contract while borrowing connections from that pool.

The deliverable is a Solr JSON writer that:

- registers via traject's `writer_class_name` setting,
- honours the existing `solr.*` / `solr_writer.*` settings surface so it is a
  drop-in for the stock writer wherever practical,
- and routes every HTTP call through an `http_connection_pool` pool keyed by
  the Solr origin.

A reader is explicitly **future scope** — design the code so a reader can reuse
the same pooling seam later, but do not build it until asked.

---

## Dependency Situation (resolved)

`http_connection_pool` requires `http ~> 6.0`. Earlier released traject gems
capped their dependency at `http < 6`, so the two could not co-install from
RubyGems, and the project bridged the gap with a Gemfile `path:` override to a
local edge checkout.

- **traject 3.9.0 (released 2026-07-21) relaxed the cap** to `http >= 3.0,
  < 7`, so traject now co-installs with `http_connection_pool` straight from
  RubyGems. The gemspec pins `traject '~> 3.9'`.
- The `path:` override is **no longer needed**. It is commented out in the
  `Gemfile` (kept as a hook in case a local traject checkout is ever needed
  again, e.g. to test an unreleased fix) — do not re-enable it for normal work.
- Do **not** hardcode absolute local filesystem paths anywhere in committed
  source, specs, or docs. Any local override lives in the `Gemfile` and refers
  to a sibling checkout by relative path.

---

## Non-Negotiable Constraints

### 1. Git and publishing
- **You may `git commit`. You may NEVER `git push`** — recommend the push
  command and let the user run it. This also covers `gem push`, `gem release`,
  `rake release`, and `git push --force` (all forbidden; user-only).
- Follow `~/.gitignore` hygiene: never stage `Gemfile.lock` (it is gitignored
  here), never use `git add -A`/`git add .` — add files by name, and check
  `.gitignore` before staging.
- Verify no secrets (Solr credentials, tokens) are ever committed.

### 2. Test-driven development
- **RSpec, TDD.** Write a failing spec before implementation code. See the
  RSpec section below.
- The whole point of the gem is concurrency-safe pooling, so writer behaviour
  under a multi-thread `solr_writer.thread_pool` must be covered by specs, not
  assumed.

### 3. Thread safety, Sidekiq, Zeitwerk, and Rails compatibility (MUST)
This gem must be as safe and portable to embed as `http_connection_pool` is.
These are hard requirements, not aspirations:

- **Thread safety is mandatory.** The writer is exercised concurrently — both
  by traject's own `solr_writer.thread_pool` and by hosting apps. All shared
  state must be safe under concurrent access. Prefer `concurrent-ruby`
  primitives (`Concurrent::AtomicFixnum`, `Concurrent::Map`, etc.) as the stock
  `SolrJsonWriter` does; never guard the hot path with a coarse global `Mutex`.
  Let the underlying `http_connection_pool` own connection checkout/return —
  never hold a borrowed connection across threads.
- **Sidekiq >= 8 compatibility is a target.** The writer must be usable from
  inside a Sidekiq >= 8 worker: instances may be created and torn down per job,
  many workers/threads run concurrently, and the process forks. Rely on
  `http_connection_pool`'s fork-safety (`connection_pool >= 2.5`
  `auto_reload_after_fork`); do not cache raw sockets or connection objects
  across a fork in this gem. Cover the "used from a background job / forked
  worker" path with specs, mirroring the sibling gem's background-job specs.
- **Zeitwerk + Rails compatibility is a target.** The gem must coexist cleanly
  with a Rails app's Zeitwerk loader and not corrupt eager-loading. Keep the
  file/constant layout Zeitwerk-conformant (file path matches constant name)
  even though traject itself loads via plain `require`. No Rails **runtime**
  dependency — Rails/Zeitwerk are **test-only** concerns, verified by
  integration specs (mirror `http_connection_pool`'s Rails-compat and
  clean-subprocess Zeitwerk specs). Do not add `rails`, `activesupport`, or
  `zeitwerk` to `spec.add_dependency`.

### 4. Respect the traject writer contract
A traject writer is any class that responds to:
- `initialize(settings)` — receives a `Traject::Indexer::Settings` (a Hash).
- `put(context)` — enqueue one `Traject::Indexer::Context` for output.
- `close` — flush remaining work, shut down threads, optionally commit.

`SolrJsonWriter` additionally provides `flush`, `commit`, `delete`,
`delete_all!`, and `skipped_record_count`. Mirror this surface so the writer is
a genuine drop-in. **Do not invent a new settings vocabulary** — reuse the
documented `solr.*` and `solr_writer.*` keys. New settings, if unavoidable, go
under a clearly namespaced prefix and must be documented.

### 5. Use the pool through its public API
- Integrate via `http_connection_pool`'s public surface (the `Connectable`
  mixin / `Registry` / `Pool`). Do not reach into its internals or reimplement
  keep-alive, mutexes, or socket handling.
- `base_url` for a pool is an **origin** (`scheme://host:port`); request paths
  (e.g. `/solr/<core>/update/json`) are **relative** and passed per request.
- Solr basic-auth credentials and content-type headers belong in
  `pool_options` (e.g. `headers:`), never baked into the origin. Pools are
  keyed by a SHA-256 digest of `(origin, options)`, so distinct credentials get
  distinct pools automatically — never defeat that isolation.
- `pool_options` **replaces, does not merge**. If merge semantics are needed,
  the caller composes the hash explicitly.
- `http_connection_pool` rejects non-scalar option values such as
  `ssl_context:` (raises `OptionKeyError`). Do not pass one; translate SSL
  needs through supported options or document the limitation.

### 6. No leakage of credentials in logs or errors
- The stock writer deliberately strips embedded user/password from the update
  URL before logging (`determine_solr_update_url`). Preserve that: never log or
  raise a message containing basic-auth credentials or auth headers.

### 7. Ruby and portability
- `required_ruby_version >= 3.3.0`. Target and test on **MRI (CRuby)**. JRuby is
  not verified — do not claim JRuby support until it is exercised.

---

## Code Style

- **RuboCop is authoritative and must be clean before any commit.** Config is
  `.rubocop.yml`; it enforces **single-quoted** non-interpolated string literals
  (`Style/StringLiterals: single_quotes`) — follow it. Use double quotes only
  when the string interpolates.
- Every Ruby file begins with `# frozen_string_literal: true`.
- Run `bundle exec rubocop -a` to auto-fix correctable offences. Never silence a
  cop with an inline `# rubocop:disable` unless there is genuinely no
  alternative — restructure or extract a method instead.
- Comments explain *why* (hidden constraints, invariants, workarounds), not
  *what*. Prefer `attr_reader` over hand-written getters. Keep methods short.
- Plugins are declared with `plugins:` syntax in `.rubocop.yml`:
  `rubocop-performance`, `rubocop-rake`, `rubocop-rspec`.

---

## RSpec

- **Never use apostrophes in `it`/`describe`/`context` strings** — `it 'a b's c'`
  is a Ruby `SyntaxError`. Rephrase to avoid the apostrophe.
- Helper methods/classes for specs go in a `spec/support` module included by tag
  — never define a top-level `class`/`def` in a spec file (it leaks a global
  constant). `spec/support/**/*.rb` should be auto-required by `spec_helper.rb`.
- Use `after do` (not `after(:each) do`) for teardown. Reset any global pool
  registry between examples so state never leaks (mirror the sibling gem's
  `Registry.reset!` teardown pattern).
- Stub Solr HTTP at the pool/connection boundary so unit specs do not require a
  live Solr. Reserve live-Solr exercises for clearly tagged integration specs.
- Concurrency is a first-class behaviour: cover `put`/`send_batch`/`close` under
  a threaded `solr_writer.thread_pool`, not just the single-thread path.
- Rails/Zeitwerk/Sidekiq compatibility lives in tagged integration specs (see
  constraint 3); keep them out of the fast unit path.

---

## Documentation

- **Whenever a change affects behaviour, settings, dependencies, or usage,
  update `README.md` and any relevant files under `docs/` in the same change.**
  This is standing — do not wait to be asked.
- Document the settings the writer honours, the temporary edge-traject
  dependency and how to remove it, and a `writer_class_name` usage example.
- Markdown: one `#` H1 per file, sentence-case headings in nesting order, fenced
  code blocks with a language tag, blank lines around headings/lists/fences.

---

## File / Constant Layout

Namespaced under `Traject::SolrPool` (traject convention; traject does not use
Zeitwerk itself — load with `require`/`require_relative`, not autoloading). The
layout must still be **Zeitwerk-conformant** (file path matches constant name)
so a host Rails app's loader stays happy — verify with an integration spec.

```
lib/
  traject/solr_pool.rb               # entry point
  traject/solr_pool/
    version.rb                       # Traject::SolrPool::VERSION
    ...                              # writer + supporting classes (TBD in design)
```

`version.rb` defines `Traject::SolrPool::VERSION`. Keep the constant tree
matching the file tree.

---

## Rake Tasks

| Task                      | What it does                                          |
| ------------------------- | ----------------------------------------------------- |
| `rake` / `rake ci`        | `bundle:audit:check` (offline) → RuboCop → RSpec      |
| `rake audit`              | `bundle:audit:update` (network) → `bundle:audit:check`|
| `rake spec`               | RSpec only                                            |
| `rake rubocop`            | RuboCop only                                          |
| `rake bundle:audit:check` | Offline CVE scan                                      |
| `rake build:checksum`     | Build, then write SHA-256 + SHA-512 to `checksums/` (gitignored) |
| `rake bump:patch`         | Bump patch version in version.rb, print release commands |
| `rake bump:minor`         | Bump minor version in version.rb, print release commands |
| `rake bump:major`         | Bump major version in version.rb, print release commands |

`rake ci` must run clean before any commit. Never bypass bundler-audit.

## Continuous integration

`.github/workflows/ci.yml` runs on push to `main` and on PRs: a `test` matrix
over MRI Ruby `3.3` and `3.4` running `rake ci` (offline audit + RuboCop +
RSpec), plus a separate `security` job running `rake audit` (network advisory-DB
refresh + check). MRI only — mirrors `http_connection_pool`'s CI. `Gemfile.lock`
is gitignored, so CI resolves dependencies fresh each run.

`.github/workflows/release.yml` triggers on a `v*.*.*` tag: it verifies the tag
matches `Traject::SolrPool::VERSION`, re-runs the specs, publishes via
`rubygems/release-gem` (OIDC Trusted Publishing — no stored API key), then
checksums the published gem and creates a GitHub Release with the gem and
checksum files attached. `gem push` / `git push` / pushing a tag remain
user-only actions; `rake bump:*` only edits `version.rb` and prints the next
commands.

---

## Key Decisions (do not reverse without discussion)

1. **Pooling is delegated to `http_connection_pool`** — this gem is a thin
   traject adapter, not a second pooling implementation.
2. **Drop-in for `SolrJsonWriter`** — reuse its settings vocabulary and public
   method surface; do not fork a new configuration language.
3. **Thread-safe, Sidekiq >= 8, Zeitwerk, and Rails compatible** — first-class
   requirements verified by specs, matching `http_connection_pool`'s guarantees.
4. **Released traject only** — pin `traject '~> 3.9'` (3.9.0 lifted the
   `http < 6` cap). The old edge `path:` override is commented out in the
   Gemfile; do not re-enable it except to test an unreleased traject fix.
5. **Reader is future scope** — leave a clean seam, build only when asked.
