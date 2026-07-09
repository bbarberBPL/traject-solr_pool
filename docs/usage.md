# Usage reference

This is the fuller settings and behaviour reference for
`Traject::SolrPool::SolrJsonWriter`. See the project README for a quick start.

## Registering the writer

```ruby
require 'traject/solr_pool'

settings do
  provide 'writer_class_name', 'Traject::SolrPool::SolrJsonWriter'
  provide 'solr.url', 'http://localhost:8983/solr/my_core'
  provide 'solr_writer.thread_pool', 4
  provide 'solr_pool.pool_size', 5
end
```

The writer derives the origin (`scheme://host:port`) from the resolved update
URL and uses it as the connection pool's `base_url`. The remainder of the URL
becomes the relative request path sent on each call, so requests resolve
against the persistent origin rather than re-encoding the absolute URL.

## Settings

The writer reuses the stock `solr.*` / `solr_writer.*` vocabulary. Only
`solr_pool.pool_size` is new.

| Setting | Default | Role |
| --- | --- | --- |
| `solr.url` | (required unless `solr.update_url` set) | Base Solr URL; the `/update/json` handler is derived from it |
| `solr.update_url` | derived from `solr.url` | Full update handler URL; used verbatim when provided |
| `solr_writer.batch_size` | `100` | Documents accumulated before a batched update is sent (values below 1 are clamped to 1) |
| `solr_writer.thread_pool` | `1` | Number of background writer threads |
| `solr_writer.max_skipped` | `0` | Skip tolerance before `MaxSkippedRecordsExceeded` is raised; a negative value disables the cap |
| `solr_writer.skippable_exceptions` | http.rb-native list (see error handling) | Exceptions treated as skippable during per-record retry |
| `solr_writer.commit_on_close` | `false` | Send a commit when the writer closes; the legacy `solrj_writer.commit_on_close` key is also honoured |
| `solr_writer.solr_update_args` | none | Query params (e.g. `{ 'commitWithin' => 1000 }`) applied to every update and delete request |
| `solr_writer.commit_solr_update_args` | `{ 'commit' => 'true' }` | Query params appended to the commit request |
| `solr_writer.basic_auth_user` | embedded URI user | Basic-auth user; overrides any credentials embedded in the URL |
| `solr_writer.basic_auth_password` | embedded URI password | Basic-auth password; overrides any credentials embedded in the URL |
| `solr_writer.http_timeout` | none | Per-request HTTP timeout, passed through to the pooled connection |
| `solr_writer.pool_timeout` | pool default | Maximum time to wait for a connection checkout from the pool |
| `solr_pool.pool_size` | `solr_writer.thread_pool` + 1 | Pool capacity, sized so no writer thread starves on checkout while the caller thread can still flush and commit |

### Credential handling

Basic-auth credentials may be provided explicitly through
`solr_writer.basic_auth_user` / `solr_writer.basic_auth_password`, or embedded
in the URL (`http://user:pass@host/...`). Explicit settings take precedence.
Embedded credentials are stripped from the stored update URL and origin, so
they never appear in logs. Auth is sent as an `Authorization` header, which
means different credentials for the same host resolve to different pools and
never share connections.

### Dropped settings

Two `solr_json_writer.*` settings from the stock writer are HTTPClient-specific
and are intentionally unsupported:

- `solr_json_writer.http_client` — connection construction is owned by the
  pool, so there is no `HTTPClient` instance to inject.
- `solr_json_writer.use_packaged_certs` — an `HTTPClient` ssl_config quirk;
  http.rb uses the operating system certificate store.

## Error handling

On any non-200 response the writer raises
`Traject::SolrPool::SolrJsonWriter::BadHttpResponse`, a subclass of
`RuntimeError`. Its `#response` accessor returns the raw http.rb response, so
callers use `#code` and `#to_s` (not HTTPClient message methods). When Solr
returns a JSON body, the `error.msg` field is extracted into the exception
message.

The default `solr_writer.skippable_exceptions` list is http.rb-native:

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

Behaviour:

- A batch that fails to POST cleanly is retried one record at a time via the
  per-record path.
- A record raising a skippable exception is logged, and the skipped-record
  counter is incremented. The run aborts with `MaxSkippedRecordsExceeded` only
  once the count passes `solr_writer.max_skipped`.
- Setting `solr_writer.skippable_exceptions` explicitly replaces the default
  list with exactly your own.
- `commit`, `delete`, and `delete_all!` raise raw on failure; they are not part
  of the skip path.
- Credentials never appear in any log or error message.

## Pool lifecycle

`close` performs the writer's normal shutdown: it flushes any queued records,
runs the final batch through the thread pool, waits for the background threads
to finish, and issues a commit when `solr_writer.commit_on_close` is set.

`close` then **leaves the pool warm** in the `http_connection_pool` registry.
It does not release or tear down the pool. This lets a later writer (or a
future reader) on the same origin reuse the existing persistent connections
rather than paying to rebuild them.

Pool teardown is the host application's responsibility. Close pools explicitly
on process shutdown, or after a fork, using the registry:

```ruby
HttpConnectionPool::Registry.instance.close_all
```

Fork safety itself is inherited from `connection_pool >= 2.5`
(`auto_reload_after_fork`): this gem caches no raw sockets or connection
objects across a fork, so Sidekiq workers get fresh connections automatically.
