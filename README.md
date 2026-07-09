# Traject::SolrPool

`Traject::SolrPool::SolrJsonWriter` is a drop-in pooled replacement for the
stock `Traject::SolrJsonWriter`. It routes every Solr update through a
persistent, credential-isolated, thread-safe HTTP connection pool provided by
[`http_connection_pool`][hcp] instead of opening a fresh `HTTPClient`
connection per request.

It reuses the stock writer's `solr.*` / `solr_writer.*` settings vocabulary, so
it is a drop-in wherever those settings are practical. The writer is:

- thread-safe (shared state uses `concurrent-ruby` primitives; a borrowed
  connection is never held across threads),
- usable from Sidekiq >= 8 workers (fork-safe via `connection_pool >= 2.5`),
- Zeitwerk-conformant, and
- compatible with Rails (no Rails runtime dependency).

All four properties are verified by the test suite (unit, concurrency, Sidekiq,
Zeitwerk, and Rails-coexistence specs).

[hcp]: https://github.com/bbarberBPL/http_connection_pool

## Installation

Add the gem to your application's Gemfile:

```ruby
gem 'traject-solr_pool'
```

Then install:

```bash
bundle install
```

## Temporary edge-traject dependency

The last released version of `traject` caps its HTTP dependency at `http < 6`,
which collides with `http_connection_pool`'s `http ~> 6.0`. Edge `traject`
relaxes that cap to `http >= 3.0, < 7`, but no release ships it yet.

Until such a release exists, this project's Gemfile pins `traject` to a sibling
edge checkout via a `path:` override:

```ruby
gem 'traject', path: '../traject-edge'
```

Check out edge `traject` into a sibling directory next to this repository so
the relative path resolves.

Once a `traject` release ships the relaxed cap, remove the override: delete the
`gem 'traject', path: '...'` line from the Gemfile. The gemspec already declares
the released version constraint, so no gemspec change is needed.

## Usage

Register the writer with traject's `writer_class_name` setting:

```ruby
require 'traject/solr_pool'

settings do
  provide 'writer_class_name', 'Traject::SolrPool::SolrJsonWriter'
  provide 'solr.url', 'http://localhost:8983/solr/my_core'
  provide 'solr_writer.thread_pool', 4
  provide 'solr_pool.pool_size', 5
end
```

The origin (`scheme://host:port`) derived from `solr.url` becomes the pool's
`base_url`; the remainder of the URL becomes the relative request path. Basic
auth credentials are sent as an `Authorization` header, never baked into the
origin, so distinct credentials resolve to distinct pools and never share
connections.

## Settings

The writer honours the stock `solr.*` / `solr_writer.*` vocabulary, plus one
new namespaced setting.

| Setting | Default | Role |
| --- | --- | --- |
| `solr.url` | (required unless `solr.update_url` set) | Base Solr URL; `/update/json` is derived from it |
| `solr.update_url` | derived from `solr.url` | Full update handler URL; used verbatim when provided |
| `solr_writer.batch_size` | `100` | Documents per batched update |
| `solr_writer.thread_pool` | `1` | Number of background writer threads |
| `solr_writer.max_skipped` | `0` | Skip tolerance before `MaxSkippedRecordsExceeded` (negative disables the cap) |
| `solr_writer.skippable_exceptions` | http.rb-native list (see below) | Exceptions treated as skippable during per-record retry |
| `solr_writer.commit_on_close` | `false` | Send a commit when the writer closes (legacy `solrj_writer.commit_on_close` also honoured) |
| `solr_writer.solr_update_args` | none | Query params (e.g. `{ 'commitWithin' => 1000 }`) applied to every update and delete request |
| `solr_writer.commit_solr_update_args` | `{ 'commit' => 'true' }` | Query params for the commit request |
| `solr_writer.commit_timeout` | `600` (10 min) | Read timeout applied to the commit request only, so a slow commit is not cut off by a short `http_timeout` |
| `solr_writer.basic_auth_user` | embedded URI user | Basic-auth user (overrides credentials embedded in the URL) |
| `solr_writer.basic_auth_password` | embedded URI password | Basic-auth password (overrides credentials embedded in the URL) |
| `solr_writer.http_timeout` | none | Per-request HTTP timeout, passed to the pool connection |
| `solr_writer.pool_timeout` | pool default | Max time to wait for a connection checkout from the pool |
| `solr_pool.pool_size` | `solr_writer.thread_pool` + 1 | Pool capacity, sized so no writer thread starves on checkout while the caller thread can still flush/commit |

### Dropped settings

Two `solr_json_writer.*` settings from the stock writer are HTTPClient-specific
and are not supported:

- `solr_json_writer.http_client` — the pool owns connection construction, so
  there is no `HTTPClient` instance to inject.
- `solr_json_writer.use_packaged_certs` — an `HTTPClient` ssl_config quirk;
  http.rb uses the operating system's certificate store instead.

## Error handling

- `Traject::SolrPool::SolrJsonWriter::BadHttpResponse` (a `RuntimeError`) is
  raised on any non-200 response. Its `#response` accessor returns the raw
  http.rb response (use `#code` / `#to_s`), and it extracts Solr's JSON
  `error.msg` into the message when present.
- The default `solr_writer.skippable_exceptions` list is http.rb-native:

  ```ruby
  [
    HTTP::TimeoutError,
    HttpConnectionPool::TimeoutError,
    HTTP::ConnectionError,
    SocketError,
    Errno::ECONNREFUSED,
    Traject::SolrPool::SolrJsonWriter::BadHttpResponse
  ]
  ```

  A batch that fails is retried record by record; a record that raises a
  skippable exception is logged and counted, aborting the run only once
  `solr_writer.max_skipped` is exceeded.
- Setting `solr_writer.skippable_exceptions` explicitly replaces the default
  list entirely with your own.
- `commit`, `delete`, and `delete_all!` raise raw on failure; they are not part
  of the skip path.
- Credentials never appear in logs or error messages: auth lives in a header
  and logs show the origin only.

## Pool lifecycle

`close` flushes any queued records, waits for the background threads, and
commits when `solr_writer.commit_on_close` is set. It then **leaves the pool
warm** in the `http_connection_pool` registry so later writers (or a future
reader) on the same origin reuse it.

Teardown is the host application's concern. Close the pools explicitly on
process shutdown or after a fork, for example:

```ruby
HttpConnectionPool::Registry.instance.close_all
```

## Development

Run the full CI pipeline (offline bundler-audit, RuboCop, RSpec):

```bash
bundle exec rake ci
```

Individual tasks (`rake spec`, `rake rubocop`, `rake bundle:audit:check`) are
also available.

## Contributing

Bug reports and pull requests are welcome. Releasing and pushing are maintainer
responsibilities — contributors should not push tags or publish gems.

## License

The gem is available as open source under the terms of the [MIT License][mit].

[mit]: https://opensource.org/licenses/MIT
