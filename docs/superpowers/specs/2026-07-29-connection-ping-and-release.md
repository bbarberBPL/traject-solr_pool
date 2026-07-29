# Connection health check, release automation, and docs pass

## Summary

Three related pieces of work on `traject-solr_pool`, on top of the shipped
pooled writer:

1. A **health-check API** on the reusable `Connection` seam (`head`, `ping`,
   `ready?`), delegated by the writer, using a HEAD request against a
   configurable Solr endpoint.
2. **Release automation** (`release.yml`) mirroring the sibling
   `http_connection_pool` gem: OIDC Trusted Publishing on a `v*.*.*` tag, with
   published-gem checksums attached to a GitHub Release.
3. A **rigorous documentation pass** with worked examples, plus fixing the
   cross-gem skill/agent references to durable GitHub URLs.

## Background: http.rb persistent connections and HEAD

The http.rb wiki's persistent-connection guidance states the governing rule:
**"You must consume response before sending next request via persistent
connection"** — the body must be read off the socket (`#to_s`, `#parse`, or
`#flush`) before the next request, or the unread body corrupts the reused
socket.

A `HEAD` request has no body to drain. http.rb's `HTTP::Client#perform` calls
`@connection.finish_response` when `res.request.verb == :head`
(`lib/http/client.rb`), so a HEAD leaves the pooled socket immediately clean for
reuse. This makes HEAD both the cheapest and the safest verb for a health check
that runs against pooled, persistent connections. All health-check requests use
HEAD for this reason.

## Part 1 — Connection health-check API

### New public methods on `Traject::SolrPool::Connection`

```ruby
TRANSPORT_ERRORS = [
  HTTP::TimeoutError,
  HttpConnectionPool::TimeoutError,
  HTTP::ConnectionError,
  SocketError,
  Errno::ECONNREFUSED
].freeze

# Generic HEAD verb, mirroring the existing get/post shape. Borrows a pooled
# connection, applies a per-request timeout when given, returns HTTP::Response.
def head(path, timeout: nil)
  @adapter.with_connection do |conn|
    client = timeout ? conn.timeout(timeout) : conn
    client.head(path)
  end
end

# Low-level health probe: returns the raw HTTP::Response so a caller can
# inspect status/headers. RAISES transport errors (does not rescue).
def ping(path, timeout: nil)
  head(path, timeout: timeout)
end

# Liveness predicate. Returns true if the server answered with ANY HTTP
# response (2xx/4xx/5xx alike) — a response of any status proves the server is
# reachable. Returns false ONLY on a transport failure.
def ready?(path, timeout: nil)
  !ping(path, timeout: timeout).nil?
rescue *TRANSPORT_ERRORS
  false
end
```

### Design decisions

- **`ready?` is reachability, not readiness of a specific status.** Per the
  chosen behaviour (option b), any HTTP response — including a `405` from a
  Solr ping handler that rejects HEAD, or a `404` — means the server process
  answered and is therefore "up". Only a transport failure (connection refused,
  timeout, DNS failure, socket error) yields `false`. This tolerates Solr's
  `PingRequestHandler` not implementing HEAD across versions, which would
  otherwise make a strict-2xx check a false negative.
  - Note: `HTTP::Session#head` returns a truthy `HTTP::Response` for every
    status, so the `!ping(...).nil?` guard is `true` whenever no transport error
    was raised. It is written as an explicit nil-guard (rather than bare
    `ping(...); true`) so the method reads as "got a response object → ready".
- **`ping` raises; `ready?` rescues.** `ping` is the raw entry for callers who
  want the status code or headers and will handle their own failures. `ready?`
  is the safe boolean for guard clauses.
- **`TRANSPORT_ERRORS`** is the same set the writer already treats as skippable
  (minus `BadHttpResponse`, which is not a transport condition). It is defined
  once as a frozen constant on `Connection` and reused; the writer's skippable
  list is not refactored to depend on it (they are conceptually distinct lists —
  keep them independent to avoid coupling).

### Writer delegation

`Traject::SolrPool::SolrJsonWriter` gains thin delegators and a resolved ping
path:

```ruby
def ping(timeout: nil)
  connection.ping(@ping_path, timeout: timeout || @ping_timeout)
end

def ready?(timeout: nil)
  connection.ready?(@ping_path, timeout: timeout || @ping_timeout)
end
```

`@ping_path` and `@ping_timeout` are resolved in `configure_from_settings`
(a new `configure_ping` step):

- **`solr_writer.ping_path`** — relative request path for the health check.
  **Default:** the core ping handler derived from the resolved Solr URL:
  1. Take the path component of `@solr_update_url`.
  2. Strip a trailing `/update/json` (or `/update`) segment to get the core
     base path.
  3. Append `/admin/ping`.
  4. If no `/update...` segment is present, fall back to appending
     `/admin/ping` to the update path's directory; if even that cannot be
     derived, fall back to the update path itself so `ready?` still probes a
     real endpoint.
  A caller with an unusual layout sets `solr_writer.ping_path` explicitly.
- **`solr_writer.ping_timeout`** — per-request read timeout for the health
  check, so a hung Solr fails fast instead of blocking on the default read
  timeout. **Default:** `5` (seconds).

The ping path is a request path resolved against the pool origin, exactly like
`request_path` — it is NOT a full URL and carries no credentials (auth remains
an `Authorization` header on the pooled connection).

### Errors and edge cases

- A HEAD to a path the server maps to a body-returning handler still drains
  cleanly because http.rb suppresses the body for HEAD verbs.
- `ready?` never raises; `ping` propagates transport errors and returns non-2xx
  responses without raising (it does not wrap them in `BadHttpResponse` — the
  health path is separate from the update path).
- The pool is borrowed and returned via `with_connection`; a health check never
  holds a connection across the call.

## Part 2 — Release automation

### `.github/workflows/release.yml`

Mirror `http_connection_pool/.github/workflows/release.yml`, adapted for this
gem's name and version constant:

- **Trigger:** push of a `v*.*.*` tag.
- **Permissions:** `contents: write` (create Release, attach assets),
  `id-token: write` (OIDC token for RubyGems Trusted Publishing).
- **Steps:**
  1. Checkout + `ruby/setup-ruby` (Ruby 3.4, `bundler-cache: true`).
  2. **Verify tag matches version** — read `Traject::SolrPool::VERSION` via
     `ruby -Ilib -r traject/solr_pool/version` and compare to
     `${GITHUB_REF_NAME#v}`; fail if they differ.
  3. **Re-run `rake spec`** — a tag push does not trigger `ci.yml`, and
     dependencies resolve fresh (`Gemfile.lock` gitignored), so this guards
     against a broken artifact under a newer in-range dependency. Not RuboCop
     (style is a CI concern, not a publish blocker).
  4. **`rubygems/release-gem@v1`** — builds and `gem push`es over OIDC; leaves
     the exact published `.gem` in `pkg/`.
  5. **`rake build:checksum`** — checksum the published gem.
  6. **`gh release create`** — create the GitHub Release with the gem and both
     checksum files attached, `--generate-notes`.

### `build:checksum` Rake task

Add to the `Rakefile`, mirroring the sibling:

- `rake build` (from `bundler/gem_tasks`) builds into `pkg/`.
- **`rake build:checksum`** — after building, write
  `checksums/traject-solr_pool-<version>.sha256` and `.sha512` in
  `sha256sum -c` / `sha512sum -c` format (digest + two spaces + filename), so
  they can be verified with `shasum -c`.
- The task computes digests from the built `pkg/*.gem` using Ruby's `digest`
  stdlib (`Digest::SHA256`/`Digest::SHA512`), not a shell out, for portability.

### `.gitignore`

Add `/checksums/`. Neither the `.gem` nor its checksums are committed — the
published gem is the source of truth (`.gem` builds are not byte-stable across
zlib/RubyGems versions). This matches the sibling gem's decision and the
project memory on gem checksums.

### Non-goals

- No committed checksums, no "byte-compare a fresh build against a committed
  checksum" gate (known to fail on every release for non-reproducible `.gem`
  output).
- The release remains **user-initiated**: a human runs `rake bump:*` (if/when
  added), commits, and pushes the tag. The assistant never runs `gem push` or
  `git push`. (Version-bump Rake tasks are out of scope for this change; the
  maintainer edits `version.rb` directly for now.)

## Part 3 — Documentation pass

### README + `docs/usage.md`

- **Health check section** with worked examples:
  - Writer delegation: `writer.ready?` in a guard, `writer.ping` for the raw
    response.
  - Standalone `Connection`: `conn.ready?('/solr/core/admin/ping')`.
  - Explanation of the reachability semantics (any response = up; transport
    error = down) and the HEAD-safety rationale (one sentence + link).
- **Registry pool reuse** section: how to obtain the writer's pool from another
  class — `writer.connection` (preferred) and
  `HttpConnectionPool::Registry.instance.pool_for(origin, **matching_options)`
  (same origin + options → same pool; different options → different pool by
  design). Note that `Registry#stats` returns `Array<Hash>` and only proves a
  pool object exists locally, not that Solr is reachable — use `ready?` for
  liveness.
- **Settings table** gains `solr_writer.ping_path` and `solr_writer.ping_timeout`
  rows in both README and `docs/usage.md`.
- Proofread the entire doc set against the code: setting names, defaults, error
  class names, method signatures.

### Cross-gem skill/agent references

`docs/skills/README.md` and `docs/agents/README.md` currently point at the
sibling gem with `../../../http_connection_pool/docs/...` relative paths, which
only resolve on a machine with both repos checked out side by side. Replace with:

- **GitHub URLs** to the blob content, e.g.
  `https://github.com/bbarberBPL/http_connection_pool/tree/main/docs/skills`.
- A note that because `http_connection_pool` is a **runtime dependency**, the
  same files are available locally in its install directory — find it with
  `bundle show http_connection_pool` (or `gem which http_connection_pool`).

### Release documentation

- **README:** add a "Releasing" subsection describing the tag-triggered OIDC
  flow and the manual `rake bump`/commit/tag step (maintainer action).
- **CLAUDE.md:** update the "Continuous integration" section to describe
  `release.yml` (it currently says automated publishing is "planned but not yet
  wired"); add the `build:checksum` task to the Rake Tasks table; add a
  "Publishing and release" note that `gem push` / `git push` remain user-only.

## Testing strategy (TDD)

### `Connection` unit specs (`spec/traject/solr_pool/connection_spec.rb`)

- `head` issues a HEAD to the given path and returns the response (WebMock
  `stub_request(:head, ...)`).
- `head` applies the timeout chainable when a timeout is given (assert via a
  stubbed `conn.timeout`).
- `ping` returns the raw response object (status accessible).
- `ping` propagates a transport error (stub WebMock `to_raise`).
- `ready?` returns `true` for a 200.
- `ready?` returns `true` for a **405 and a 404** (reachability, not 2xx) —
  non-vacuous: assert the HEAD was actually requested.
- `ready?` returns `false` on a transport error (`to_raise` a connection error)
  and does not propagate.

### Writer unit specs (`spec/traject/solr_pool/solr_json_writer_spec.rb`)

- `ready?`/`ping` delegate to the connection with the resolved `@ping_path`.
- Default `ping_path` derives `<core>/admin/ping` from `solr.url` (and from
  `solr.update_url`); assert the exact path requested via WebMock.
- Explicit `solr_writer.ping_path` overrides the derived default.
- `solr_writer.ping_timeout` is passed through (default 5; override honoured).
- Credential safety unchanged: the ping request carries the `Authorization`
  header, not embedded URL creds (assert header present, URL clean).

### No new integration spec required

The health check runs through the same pooled `with_connection` path already
exercised by concurrency/Sidekiq specs; a dedicated integration spec would be
redundant. (If a quick reachability assertion is cheap to add to the existing
concurrency spec, do so, but it is not required.)

### Release workflow

Not unit-testable in-repo. Verify by: `rake build:checksum` produces valid
`shasum -c`-format files for the built gem (add a focused spec or a manual
check), and the workflow YAML is valid. The tag-verify shell step is copied
from the proven sibling workflow with only the gem name/constant changed.

## Definition of done

- `rake ci` green (bundler-audit offline + RuboCop + RSpec), all new specs
  non-vacuous.
- `Connection#head/ping/ready?` and writer delegators implemented and tested.
- `release.yml` + `build:checksum` task + `/checksums/` gitignore in place;
  `rake build:checksum` verified to emit valid checksum files.
- README, `docs/usage.md`, CLAUDE.md, and the skill/agent READMEs updated;
  cross-gem references use GitHub URLs + `bundle show` note.
- No credential material in any new log line, inspect output, or error message.
