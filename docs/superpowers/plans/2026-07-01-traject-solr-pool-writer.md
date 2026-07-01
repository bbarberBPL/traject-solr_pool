# Traject Solr Pool Writer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Traject::SolrPool::SolrJsonWriter`, a drop-in replacement for `Traject::SolrJsonWriter` that routes every Solr HTTP call through a persistent, credential-isolated connection pool from `http_connection_pool`.

**Architecture:** Two units. `Traject::SolrPool::Connection` owns all pooling (derives the origin, builds `pool_options`, binds to the pool by extending `HttpConnectionPool::Connectable` onto an adapter object) and exposes `post`/`get`. `Traject::SolrPool::SolrJsonWriter` is a fresh port of the stock writer's structure (batched queue, `Traject::ThreadPool`, skip counter, `commit`/`delete`) that delegates all HTTP to `Connection`. The `Connection` seam is designed for a future reader to reuse.

**Tech Stack:** Ruby 3.4 (floor 3.3), RSpec, WebMock, http.rb 6.x, `http_connection_pool`, traject (edge via Gemfile `path:`), concurrent-ruby.

## Global Constraints

- Ruby `>= 3.3.0`; target and test on MRI (CRuby). Do not claim JRuby support.
- Runtime deps only: `http_connection_pool ~> 0.1`, `traject` (edge via Gemfile `path:` override until a release lifts the `http < 6` cap; gemspec constraint carries a NOTE to switch to the released version). Never add Rails/Zeitwerk/Sidekiq/WebMock to `spec.add_dependency`.
- Test-only deps live in a `:test` Gemfile group (NOT `:development`): `webmock`, `activesupport`, `activejob`, `zeitwerk`, `sidekiq`.
- All non-interpolated Ruby strings use single quotes. Every `.rb` file starts with `# frozen_string_literal: true`.
- RuboCop (`single_quotes`, plugins `rubocop-performance`/`rubocop-rake`/`rubocop-rspec`, `TargetRubyVersion 3.3`) must be clean before every commit. No inline `# rubocop:disable` unless unavoidable.
- Reuse the `solr.*` / `solr_writer.*` settings vocabulary verbatim. Only new setting is `solr_pool.pool_size`.
- Never log or raise a message containing basic-auth credentials or auth headers. Origin only in logs.
- Pooling is delegated to `http_connection_pool` via its public API (`Connectable` / `Registry`). Never reach into its internals or reimplement keep-alive/sockets/mutexes.
- Thread safety is mandatory: `concurrent-ruby` primitives, no coarse global `Mutex` on the hot path. A borrowed connection is never held across threads.
- RSpec: no apostrophes in `it`/`describe`/`context` strings; `after do` teardown; reset `HttpConnectionPool::Registry` between examples; `spec/support/**` auto-required; helpers in a `spec/support` module included by tag.
- Git: commit freely, NEVER push (also no `gem push`/`rake release`). Stage files by name, never `git add -A`/`.`; never stage `Gemfile.lock` (gitignored).

**Reference:** design spec at `docs/superpowers/specs/2026-07-01-traject-solr-pool-writer-design.md`.

---

## File Structure

- `lib/traject/solr_pool.rb` — entry point; requires version, connection, writer.
- `lib/traject/solr_pool/version.rb` — `Traject::SolrPool::VERSION` (exists).
- `lib/traject/solr_pool/connection.rb` — `Traject::SolrPool::Connection` (reusable pool seam).
- `lib/traject/solr_pool/solr_json_writer.rb` — `Traject::SolrPool::SolrJsonWriter` + nested `BadHttpResponse`, `MaxSkippedRecordsExceeded`.
- `spec/spec_helper.rb` — require gem, WebMock config, Registry reset, support autoload.
- `spec/support/webmock_helpers.rb` — Solr stub helpers, tag `:solr_stub`.
- `spec/support/thread_safety_helpers.rb` — `cyclic_barrier`, tag `:thread_safety`.
- `spec/support/job_helpers.rb` — Sidekiq/ActiveJob harness, tag `:background_jobs`.
- `spec/traject/solr_pool/connection_spec.rb`
- `spec/traject/solr_pool/solr_json_writer_spec.rb`
- `spec/integration/concurrency_spec.rb`
- `spec/integration/background_job_spec.rb`
- `spec/integration/zeitwerk_compliance_spec.rb`
- `spec/integration/rails_compatibility_spec.rb`

---

## Task 1: Project scaffolding — deps, RuboCop, spec_helper, WebMock

**Files:**
- Modify: `traject-solr_pool.gemspec`
- Modify: `Gemfile`
- Modify: `spec/spec_helper.rb`
- Create: `spec/support/webmock_helpers.rb`
- Delete existing placeholder assertion in: `spec/traject/solr_pool_spec.rb`

**Interfaces:**
- Produces: a green `bundle exec rspec` + `bundle exec rubocop` baseline; `WebmockHelpers#stub_solr_update(status:, body:)` and `#stub_solr_get(...)` for later tasks; `spec_helper` resets `HttpConnectionPool::Registry.instance` after each example.

- [ ] **Step 1: Fill in the gemspec metadata and dependencies**

Replace the TODO/placeholder lines in `traject-solr_pool.gemspec`. Keep the existing `git ls-files` file list block. Set:

```ruby
  spec.summary     = 'Traject Solr JSON writer backed by a persistent, pooled, thread-safe HTTP client'
  spec.description = 'A traject plugin providing a drop-in Solr JSON writer that routes updates ' \
                     'through http_connection_pool for persistent, credential-isolated, thread-safe connections.'
  spec.homepage    = 'https://github.com/bbarberBPL/traject-solr_pool'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['homepage_uri']      = spec.homepage
  spec.metadata['source_code_uri']   = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'
```

Keep the two runtime deps already present, but correct the traject line's NOTE:

```ruby
  spec.add_dependency 'http_connection_pool', '~> 0.1'
  # NOTE: temporary floor. The last RELEASED traject caps http < 6, colliding
  # with http_connection_pool's http ~> 6.0. We depend on edge traject via a
  # Gemfile `path:` override until a release lifts that cap; then pin the real
  # released version here and remove the Gemfile override.
  spec.add_dependency 'traject', '>= 3.8.4', '~> 3.8'
```

- [ ] **Step 2: Rewrite the Gemfile test group**

Replace the `group :development, :test` block in `Gemfile` with a split: keep tooling in `:development, :test` but put the integration-only libraries in a `:test`-only group.

```ruby
group :development, :test do
  gem 'bundler-audit', '~> 0.9', require: false
  gem 'irb',           '~> 1.14'
  gem 'rake',          '~> 13.0'
  gem 'rspec',         '~> 3.13'
  gem 'rubocop',              require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rake',        require: false
  gem 'rubocop-rspec',       require: false
end

group :test do
  gem 'webmock',       '~> 3.23'
  gem 'activesupport', '~> 7.2'
  gem 'activejob',     '~> 7.2'
  gem 'zeitwerk',      '~> 2.6'
  gem 'sidekiq',       '>= 8', '< 9'
end
```

Leave the existing `gem 'traject', path: '../traject-edge'` line as-is (the temporary edge override).

- [ ] **Step 3: Run bundle install**

Run: `bundle install`
Expected: resolves successfully, writes `Gemfile.lock` (gitignored — do not stage it).

- [ ] **Step 4: Write the WebMock helper module**

Create `spec/support/webmock_helpers.rb`:

```ruby
# frozen_string_literal: true

require 'webmock/rspec'

# HTTP stubbing helpers for Solr update/get endpoints. Included into any
# example group tagged :solr_stub (wired in spec_helper.rb). WebMock intercepts
# real http.rb requests, so specs exercise the actual pool without a live Solr.
module WebmockHelpers
  SOLR_OK = { 'responseHeader' => { 'status' => 0, 'QTime' => 1 } }.freeze

  def stub_solr_update(url, status: 200, body: SOLR_OK.to_json)
    stub_request(:post, url).to_return(
      status: status,
      body: body,
      headers: { 'Content-Type' => 'application/json' }
    )
  end

  def stub_solr_get(url, status: 200, body: '{}')
    stub_request(:get, url).to_return(
      status: status,
      body: body,
      headers: { 'Content-Type' => 'application/json' }
    )
  end
end
```

- [ ] **Step 5: Rewrite spec_helper.rb**

Replace `spec/spec_helper.rb` with:

```ruby
# frozen_string_literal: true

require 'traject/solr_pool'
require 'webmock/rspec'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include WebmockHelpers, :solr_stub

  # Every example starts with a clean global pool registry so pools never leak
  # between examples (locally-built pools must be closed by their own example).
  config.after do
    HttpConnectionPool::Registry.instance.close_all
  end
end
```

- [ ] **Step 6: Replace the placeholder version spec**

Overwrite `spec/traject/solr_pool_spec.rb` (removing the failing `expect(false).to eq(true)` placeholder):

```ruby
# frozen_string_literal: true

RSpec.describe Traject::SolrPool do
  it 'has a version number' do
    expect(Traject::SolrPool::VERSION).not_to be_nil
  end
end
```

- [ ] **Step 7: Run the suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: RSpec green (1 example), RuboCop clean. Confirm `HttpConnectionPool::Registry` responds to `close_all` (it is the documented teardown method); if the version installed uses `reset!`, use `HttpConnectionPool::Registry.reset!` instead.

- [ ] **Step 8: Commit**

```bash
git add traject-solr_pool.gemspec Gemfile spec/spec_helper.rb spec/support/webmock_helpers.rb spec/traject/solr_pool_spec.rb
git commit -m "Scaffold deps, RuboCop, and WebMock-backed spec harness"
```

---

## Task 2: Connection — origin derivation and pool binding

**Files:**
- Create: `lib/traject/solr_pool/connection.rb`
- Create: `spec/traject/solr_pool/connection_spec.rb`
- Modify: `lib/traject/solr_pool.rb`

**Interfaces:**
- Consumes: `HttpConnectionPool::Connectable`, `HttpConnectionPool::Registry`.
- Produces: `Traject::SolrPool::Connection.new(origin:, pool_size:, pool_timeout:, headers: {}, auth: nil, timeout: nil)`; readers `#origin`; methods `#post(path, body:)` and `#get(path, params: {})` returning an http.rb response (`HTTP::Response`); `#release` closing this connection's pool via the registry.

- [ ] **Step 1: Write failing tests for origin binding and requests**

Create `spec/traject/solr_pool/connection_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Traject::SolrPool::Connection, :solr_stub do
  subject(:connection) { described_class.new(origin: 'http://solr.test:8983', pool_size: 2) }

  it 'exposes the origin it was built with' do
    expect(connection.origin).to eq('http://solr.test:8983')
  end

  it 'posts a body to a relative path resolved against the origin' do
    stub = stub_solr_update('http://solr.test:8983/solr/core/update')
    connection.post('/solr/core/update', body: '[]')
    expect(stub).to have_been_requested
  end

  it 'gets a relative path with query params resolved against the origin' do
    stub = stub_solr_get('http://solr.test:8983/solr/core/get?id=abc')
    connection.get('/solr/core/get', params: { id: 'abc' })
    expect(stub).to have_been_requested
  end

  it 'sends the configured auth as an Authorization header' do
    connection = described_class.new(origin: 'http://solr.test:8983', pool_size: 1,
                                     auth: 'Basic dXNlcjpwYXNz')
    stub = stub_solr_update('http://solr.test:8983/x')
           .with(headers: { 'Authorization' => 'Basic dXNlcjpwYXNz' })
    connection.post('/x', body: '[]')
    expect(stub).to have_been_requested
  end

  it 'gives different credentials different pools' do
    a = described_class.new(origin: 'http://solr.test:8983', pool_size: 1, auth: 'Basic AAA')
    b = described_class.new(origin: 'http://solr.test:8983', pool_size: 1, auth: 'Basic BBB')
    expect(a.send(:pool)).not_to be(b.send(:pool))
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/traject/solr_pool/connection_spec.rb`
Expected: FAIL — `uninitialized constant Traject::SolrPool::Connection`.

- [ ] **Step 3: Implement Connection**

Create `lib/traject/solr_pool/connection.rb`:

```ruby
# frozen_string_literal: true

require 'http_connection_pool'

module Traject
  module SolrPool
    # Reusable persistent-connection seam over http_connection_pool. Owns origin
    # binding and pool_options construction; exposes post/get that borrow a
    # pooled HTTP::Session. A future reader can reuse this unchanged.
    class Connection
      attr_reader :origin

      def initialize(origin:, pool_size:, pool_timeout: nil, headers: {}, auth: nil, timeout: nil)
        @origin       = origin
        @pool_size    = pool_size
        @pool_timeout = pool_timeout
        @pool_options = build_pool_options(headers, auth, timeout)
        @adapter      = build_adapter
      end

      def post(path, body:)
        @adapter.with_connection { |conn| conn.post(path, body: body) }
      end

      def get(path, params: {})
        @adapter.with_connection { |conn| conn.get(path, params: params) }
      end

      def release
        @adapter.release_connection_pool
      end

      private

      # Auth is passed through http_connection_pool's :auth option, which folds
      # it into an Authorization header. Nil values are dropped so they never
      # widen the pool key.
      def build_pool_options(headers, auth, timeout)
        opts = { headers: headers }
        opts[:auth]    = auth    if auth
        opts[:timeout] = timeout if timeout
        opts
      end

      def build_adapter
        origin       = @origin
        pool_size    = @pool_size
        pool_timeout = @pool_timeout
        pool_options = @pool_options

        adapter = Object.new
        adapter.extend(HttpConnectionPool::Connectable)
        adapter.base_url     = origin
        adapter.pool_size    = pool_size
        adapter.pool_timeout = pool_timeout if pool_timeout
        adapter.pool_options = pool_options
        adapter
      end

      def pool
        @adapter.connection_pool
      end
    end
  end
end
```

- [ ] **Step 4: Wire the require into the entry point**

Modify `lib/traject/solr_pool.rb` to require the connection (add after the version require):

```ruby
require_relative 'solr_pool/connection'
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/traject/solr_pool/connection_spec.rb`
Expected: PASS (5 examples). If http.rb rejects `params: {}` on a plain get, pass `params:` only when non-empty — adjust `get` to `path` vs `path, params:` accordingly and re-run.

- [ ] **Step 6: RuboCop**

Run: `bundle exec rubocop lib/traject/solr_pool/connection.rb spec/traject/solr_pool/connection_spec.rb`
Expected: clean (run `bundle exec rubocop -a` to auto-fix, then re-run).

- [ ] **Step 7: Commit**

```bash
git add lib/traject/solr_pool/connection.rb lib/traject/solr_pool.rb spec/traject/solr_pool/connection_spec.rb
git commit -m "Add Connection: origin-bound pooled HTTP seam"
```

---

## Task 3: Writer skeleton — settings, URL derivation, Connection wiring

**Files:**
- Create: `lib/traject/solr_pool/solr_json_writer.rb`
- Create: `spec/traject/solr_pool/solr_json_writer_spec.rb`
- Modify: `lib/traject/solr_pool.rb`

**Interfaces:**
- Consumes: `Traject::SolrPool::Connection` from Task 2.
- Produces: `Traject::SolrPool::SolrJsonWriter.new(settings)` responding to `#settings`, `#solr_update_url`, `#connection` (a `Connection`), `#pool_size`; class `Traject::SolrPool::SolrJsonWriter::BadHttpResponse < RuntimeError` with `#response`; `#solr_update_url_with_query(query_params)`.

- [ ] **Step 1: Write failing tests for construction and URL derivation**

Create `spec/traject/solr_pool/solr_json_writer_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Traject::SolrPool::SolrJsonWriter, :solr_stub do
  def writer(settings = {})
    described_class.new({ 'solr.url' => 'http://solr.test:8983/solr/core' }.merge(settings))
  end

  describe 'update url derivation' do
    it 'derives the update handler from solr.url' do
      expect(writer.solr_update_url).to eq('http://solr.test:8983/solr/core/update/json')
    end

    it 'uses solr.update_url verbatim when provided' do
      w = described_class.new('solr.update_url' => 'http://solr.test:8983/solr/core/update')
      expect(w.solr_update_url).to eq('http://solr.test:8983/solr/core/update')
    end

    it 'raises when neither solr.url nor solr.update_url is set' do
      expect { described_class.new({}) }.to raise_error(ArgumentError)
    end
  end

  describe 'connection binding' do
    it 'builds a Connection bound to the solr origin' do
      expect(writer.connection.origin).to eq('http://solr.test:8983')
    end
  end

  describe 'pool size' do
    it 'defaults pool_size to the writer thread pool plus caller headroom' do
      expect(writer('solr_writer.thread_pool' => 3).pool_size).to eq(4)
    end

    it 'honours an explicit solr_pool.pool_size' do
      expect(writer('solr_pool.pool_size' => 9).pool_size).to eq(9)
    end
  end

  describe 'query params' do
    it 'appends solr_update_args as a query string' do
      w = writer('solr_writer.solr_update_args' => { commitWithin: 1000 })
      expect(w.solr_update_url_with_query(w.instance_variable_get(:@solr_update_args)))
        .to eq('http://solr.test:8983/solr/core/update/json?commitWithin=1000')
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: FAIL — `uninitialized constant Traject::SolrPool::SolrJsonWriter`.

- [ ] **Step 3: Implement the writer skeleton**

Create `lib/traject/solr_pool/solr_json_writer.rb`:

```ruby
# frozen_string_literal: true

require 'json'
require 'uri'
require 'concurrent/atomic/atomic_fixnum'
require 'traject/util'
require 'traject/thread_pool'

require_relative 'connection'

module Traject
  module SolrPool
    # Drop-in replacement for Traject::SolrJsonWriter that sends every Solr HTTP
    # call through a persistent http_connection_pool pool. Reuses the stock
    # writer's settings vocabulary and public surface; all HTTP is delegated to
    # Traject::SolrPool::Connection.
    class SolrJsonWriter
      URI_REGEXP = URI::DEFAULT_PARSER.make_regexp.freeze

      DEFAULT_MAX_SKIPPED = 0
      DEFAULT_BATCH_SIZE  = 100

      attr_reader :settings, :thread_pool_size, :batched_queue, :solr_update_url,
                  :connection, :pool_size

      def initialize(arg_settings)
        @settings = Traject::Indexer::Settings.new(arg_settings)

        @max_skipped = (@settings['solr_writer.max_skipped'] || DEFAULT_MAX_SKIPPED).to_i
        @max_skipped = nil if @max_skipped.negative?

        @solr_update_url, basic_auth_user, basic_auth_password = determine_solr_update_url

        @batch_size = (@settings['solr_writer.batch_size'] || DEFAULT_BATCH_SIZE).to_i
        @batch_size = 1 if @batch_size < 1

        @skipped_record_incrementer = Concurrent::AtomicFixnum.new(0)
        @thread_pool_size = (@settings['solr_writer.thread_pool'] || 1).to_i

        @pool_size = (@settings['solr_pool.pool_size'] || (@thread_pool_size + 1)).to_i
        @connection = build_connection(basic_auth_user, basic_auth_password)

        @batched_queue = Queue.new
        @thread_pool = Traject::ThreadPool.new(@thread_pool_size)

        @commit_on_close = (@settings['solr_writer.commit_on_close'] ||
                            @settings['solrj_writer.commit_on_close']).to_s == 'true'
        @solr_update_args = @settings['solr_writer.solr_update_args']
        @commit_solr_update_args = @settings['solr_writer.commit_solr_update_args']

        logger.info("   #{self.class.name} writing to '#{@solr_update_url}' " \
                    "#{'(with HTTP basic auth) ' if basic_auth_user || basic_auth_password}" \
                    "in batches of #{@batch_size} with #{@thread_pool_size} bg threads")
      end

      def solr_update_url_with_query(query_params)
        return @solr_update_url unless query_params

        "#{@solr_update_url}?#{URI.encode_www_form(query_params)}"
      end

      def logger
        settings['logger'] ||= Yell.new($stderr, level: 'gt.fatal')
      end

      private

      # Splits the origin (scheme://host:port -> pool base_url) from the request
      # path, and hands auth to the Connection as an Authorization header value
      # so credentials live in pool_options, never in the origin or logs.
      def build_connection(user, password)
        uri = URI.parse(@solr_update_url)
        origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"

        Connection.new(
          origin: origin,
          pool_size: @pool_size,
          pool_timeout: @settings['solr_writer.pool_timeout'],
          auth: basic_auth_header(user, password),
          timeout: @settings['solr_writer.http_timeout']
        )
      end

      def basic_auth_header(user, password)
        return nil unless user || password

        require 'base64'
        "Basic #{Base64.strict_encode64("#{user}:#{password}")}"
      end

      def request_path
        uri = URI.parse(@solr_update_url)
        uri.query ? "#{uri.path}?#{uri.query}" : uri.path
      end

      def determine_solr_update_url
        url = if settings['solr.update_url']
                check_solr_update_url(settings['solr.update_url'])
              else
                derive_solr_update_url_from_solr_url(settings['solr.url'])
              end

        parsed = URI.parse(url)
        user_from_uri = parsed.user
        password_from_uri = parsed.password
        parsed.user = nil
        parsed.password = nil

        [parsed.to_s,
         @settings['solr_writer.basic_auth_user'] || user_from_uri,
         @settings['solr_writer.basic_auth_password'] || password_from_uri]
      end

      def check_solr_update_url(url)
        unless /^#{URI_REGEXP}$/.match?(url)
          raise ArgumentError, "#{self.class.name} setting `solr.update_url` doesn't look like a URL: `#{url}`"
        end

        url
      end

      def derive_solr_update_url_from_solr_url(url)
        raise ArgumentError, "#{self.class.name}: Neither solr.update_url nor solr.url set; need at least one" if url.nil?

        unless /^#{URI_REGEXP}$/.match?(url)
          raise ArgumentError, "#{self.class.name} setting `solr.url` doesn't look like a URL: `#{url}`"
        end

        [url.chomp('/'), 'update', 'json'].join('/')
      end
    end
  end
end
```

- [ ] **Step 4: Require yell and wire the entry point**

At the top of `solr_json_writer.rb` the writer uses `Yell` and `Traject::Indexer::Settings`; both load via `require 'traject'`. Modify `lib/traject/solr_pool.rb` to require the writer after the connection:

```ruby
require_relative 'solr_pool/solr_json_writer'
```

Confirm `require 'traject'` at the top of `lib/traject/solr_pool.rb` remains (it defines `Traject::Indexer::Settings` and pulls in `yell`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: PASS (8 examples).

- [ ] **Step 6: RuboCop**

Run: `bundle exec rubocop -a lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb && bundle exec rubocop lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: clean. If `Metrics/MethodLength` flags `initialize`, extract a private `configure_from_settings` helper rather than disabling the cop.

- [ ] **Step 7: Commit**

```bash
git add lib/traject/solr_pool/solr_json_writer.rb lib/traject/solr_pool.rb spec/traject/solr_pool/solr_json_writer_spec.rb
git commit -m "Add writer skeleton: settings, URL derivation, Connection wiring"
```

---

## Task 4: Writer output path — put, send_batch, send_single, BadHttpResponse

**Files:**
- Modify: `lib/traject/solr_pool/solr_json_writer.rb`
- Modify: `spec/traject/solr_pool/solr_json_writer_spec.rb`

**Interfaces:**
- Consumes: `#connection`, `#request_path`, `@batched_queue`, `@thread_pool` from Task 3.
- Produces: `#put(context)`, `#flush`, `#send_batch(batch)`, `#send_single(context)`, `#skipped_record_count`; nested `BadHttpResponse < RuntimeError` (with `#response`) and `MaxSkippedRecordsExceeded < RuntimeError`; default `#skippable_exceptions`.

- [ ] **Step 1: Write failing tests for the output path**

Add to `spec/traject/solr_pool/solr_json_writer_spec.rb` inside the top-level describe:

```ruby
  def context(hash)
    Traject::Indexer::Context.new(output_hash: hash)
  end

  describe 'put and batching' do
    it 'posts a full batch as a JSON array once batch_size is reached' do
      stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
      w = writer('solr_writer.batch_size' => 2, 'solr_writer.thread_pool' => 0)
      w.put(context('id' => '1'))
      w.put(context('id' => '2'))
      expect(stub.with { |req| JSON.parse(req.body).length == 2 }).to have_been_requested
    end

    it 'does not post before the batch is full' do
      stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
      w = writer('solr_writer.batch_size' => 5, 'solr_writer.thread_pool' => 0)
      w.put(context('id' => '1'))
      expect(stub).not_to have_been_requested
    end
  end

  describe 'error handling' do
    it 'retries a failed batch as individual records' do
      stub_request(:post, 'http://solr.test:8983/solr/core/update/json')
        .to_return({ status: 500, body: '{}' }, { status: 200, body: '{}' })
      w = writer('solr_writer.batch_size' => 1, 'solr_writer.thread_pool' => 0,
                 'solr_writer.max_skipped' => -1)
      expect { w.put(context('id' => '1')) }.not_to raise_error
    end

    it 'raises MaxSkippedRecordsExceeded past the skip limit' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json', status: 500, body: '{}')
      w = writer('solr_writer.batch_size' => 1, 'solr_writer.thread_pool' => 0,
                 'solr_writer.max_skipped' => 0)
      expect { w.put(context('id' => '1')) }
        .to raise_error(described_class::MaxSkippedRecordsExceeded)
    end

    it 'counts skipped records' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json', status: 500, body: '{}')
      w = writer('solr_writer.batch_size' => 1, 'solr_writer.thread_pool' => 0,
                 'solr_writer.max_skipped' => -1)
      w.put(context('id' => '1'))
      expect(w.skipped_record_count).to eq(1)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/traject/solr_pool/solr_json_writer_spec.rb -e 'put and batching'`
Expected: FAIL — `undefined method 'put'`.

- [ ] **Step 3: Implement the output path**

Add these public methods to `SolrJsonWriter` (above `private`), and the nested classes + `skippable_exceptions` at the appropriate scope:

```ruby
      def put(context)
        @thread_pool.raise_collected_exception!
        @batched_queue << context
        return if @batched_queue.size < @batch_size

        batch = Traject::Util.drain_queue(@batched_queue)
        @thread_pool.maybe_in_thread_pool(batch) { |b| send_batch(b) }
      end

      def flush
        send_batch(Traject::Util.drain_queue(@batched_queue))
      end

      def send_batch(batch)
        return if batch.empty?

        json_package = JSON.generate(batch.map(&:output_hash))
        begin
          resp = connection.post(request_path, body: json_package)
        rescue StandardError => e
          exception = e
        end

        return if exception.nil? && resp.status == 200

        log_batch_failure(exception, resp)
        batch.each { |c| send_single(c) }
      end

      def send_single(context)
        json_package = JSON.generate([context.output_hash])
        resp = connection.post(request_path, body: json_package)
        unless resp.status == 200
          raise BadHttpResponse.new("Unexpected HTTP response status #{resp.code} from POST", resp)
        end
      rescue *skippable_exceptions => e
        handle_skipped(context, e)
      end

      def skipped_record_count
        @skipped_record_incrementer.value
      end
```

Add these private helpers:

```ruby
      def log_batch_failure(exception, resp)
        message = if exception
                    Traject::Util.exception_to_log_message(exception)
                  else
                    "Solr response: #{resp.code}: #{resp.to_s}"
                  end
        logger.error("Error in Solr batch add. Will retry documents individually " \
                     "at performance penalty: #{message}")
      end

      def handle_skipped(context, exception)
        msg = if exception.is_a?(BadHttpResponse)
                "Solr error response: #{exception.response.code}: #{exception.response.to_s}"
              else
                Traject::Util.exception_to_log_message(exception)
              end
        logger.error("Could not add record #{context.record_inspect}: #{msg}")

        @skipped_record_incrementer.increment
        return unless @max_skipped && skipped_record_count > @max_skipped

        raise MaxSkippedRecordsExceeded,
              "#{self.class.name}: Exceeded maximum number of skipped records " \
              "(#{@max_skipped}): aborting: #{exception.message}"
      end

      def skippable_exceptions
        @skippable_exceptions ||= settings['solr_writer.skippable_exceptions'] || [
          HTTP::TimeoutError,
          HttpConnectionPool::TimeoutError,
          HTTP::ConnectionError,
          SocketError,
          Errno::ECONNREFUSED,
          BadHttpResponse
        ]
      end
```

Add nested classes inside the `SolrJsonWriter` class body (near the top, after the constants):

```ruby
      class MaxSkippedRecordsExceeded < RuntimeError; end

      # Mirrors the stock writer's BadHttpResponse, but its #response is an
      # http.rb HTTP::Response (use #code / #to_s), not an HTTPClient message.
      class BadHttpResponse < RuntimeError
        attr_reader :response

        def initialize(msg, response = nil)
          solr_error = find_solr_error(response)
          msg = "#{msg}: #{solr_error}" if solr_error
          super(msg)
          @response = response
        end

        private

        def find_solr_error(response)
          return nil unless response&.to_s && response.headers['Content-Type'].to_s.start_with?('application/json')

          JSON.parse(response.to_s).dig('error', 'msg')
        rescue JSON::ParserError
          nil
        end
      end
```

Ensure `require 'http'` is present at the top of the file (for the error constants). Add it with the other requires.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: PASS (all examples). Note `solr_writer.thread_pool => 0` runs inline (null thread pool), so failures surface synchronously.

- [ ] **Step 5: RuboCop**

Run: `bundle exec rubocop -a lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb && bundle exec rubocop lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: clean. `Style/StringConcatenation` / `Lint/RedundantStringCoercion` may flag `resp.to_s` in interpolation — replace `"#{...}: #{resp.to_s}"` with `"#{...}: #{resp}"` where the cop asks.

- [ ] **Step 6: Commit**

```bash
git add lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb
git commit -m "Add writer output path: put/send_batch/send_single with error mapping"
```

---

## Task 5: Writer lifecycle — close, commit, delete, delete_all!

**Files:**
- Modify: `lib/traject/solr_pool/solr_json_writer.rb`
- Modify: `spec/traject/solr_pool/solr_json_writer_spec.rb`

**Interfaces:**
- Consumes: everything from Tasks 3–4.
- Produces: `#close`, `#commit(query_params = nil)`, `#delete(id)`, `#delete_all!`. `#close` flushes, drains the thread pool, optionally commits, and does NOT release the pool (leaves it warm).

- [ ] **Step 1: Write failing tests for lifecycle**

Add to the spec file:

```ruby
  describe 'close' do
    it 'flushes queued records on close' do
      stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
      w = writer('solr_writer.batch_size' => 100, 'solr_writer.thread_pool' => 0)
      w.put(context('id' => '1'))
      w.close
      expect(stub).to have_been_requested
    end

    it 'leaves the pool warm after close' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json')
      w = writer('solr_writer.thread_pool' => 0)
      origin = w.connection.origin
      w.close
      expect(HttpConnectionPool::Registry.instance.stats.map { |s| s[:origin] }).to include(origin)
    end

    it 'commits on close when configured' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json')
      commit = stub_solr_get('http://solr.test:8983/solr/core/update/json?commit=true')
      w = writer('solr_writer.thread_pool' => 0, 'solr_writer.commit_on_close' => 'true')
      w.close
      expect(commit).to have_been_requested
    end
  end

  describe 'delete' do
    it 'posts a delete-by-id document' do
      stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
             .with { |req| JSON.parse(req.body) == { 'delete' => 'abc' } }
      writer('solr_writer.thread_pool' => 0).delete('abc')
      expect(stub).to have_been_requested
    end

    it 'raises on a non-200 delete' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json', status: 500)
      expect { writer('solr_writer.thread_pool' => 0).delete('abc') }.to raise_error(RuntimeError)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/traject/solr_pool/solr_json_writer_spec.rb -e 'close'`
Expected: FAIL — `undefined method 'close'`.

- [ ] **Step 3: Implement lifecycle methods**

Add as public methods:

```ruby
      def close
        @thread_pool.raise_collected_exception!

        batch = Traject::Util.drain_queue(@batched_queue)
        @thread_pool.maybe_in_thread_pool { send_batch(batch) } unless batch.empty?

        if @thread_pool_size&.positive?
          elapsed = @thread_pool.shutdown_and_wait
          logger.warn("Waited #{elapsed}s for all threads") if elapsed > 60
          logger.warn("#{self.class.name}: #{skipped_record_count} skipped records") if skipped_record_count.positive?
        end

        @thread_pool.raise_collected_exception!
        commit if @commit_on_close
        # Pool is intentionally left warm in the registry for reuse by later
        # writers/readers on this origin; teardown is the host app's concern.
      end

      def commit(query_params = nil)
        query_params ||= @commit_solr_update_args || { 'commit' => 'true' }
        logger.info("#{self.class.name} sending commit to solr at url #{@solr_update_url}...")

        resp = connection.get(request_path_for(query_params))
        raise "Could not commit to Solr: #{resp.code} #{resp}" unless resp.status == 200
      end

      def delete(id)
        json_package = JSON.generate(delete: id)
        resp = connection.post(request_path, body: json_package)
        raise "Could not delete #{id.inspect}, http response #{resp.code}: #{resp}" unless resp.status == 200
      end

      def delete_all!
        delete(query: '*:*')
      end
```

Add a private helper to build a path with query params for GET-based commit:

```ruby
      def request_path_for(query_params)
        base = request_path
        return base unless query_params

        separator = base.include?('?') ? '&' : '?'
        "#{base}#{separator}#{URI.encode_www_form(query_params)}"
      end
```

Note: the `delete(query: '*:*')` path passes a hash whose value is a query, matching the stock writer, which posts `{delete: id}`; here `id` may be a hash. This mirrors the stock behaviour exactly.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: PASS (all). If the commit stub URL mismatches, print the actual requested URL with `WebMock.after_request` or check `request_path_for` output against the stub in Step 1 and align.

- [ ] **Step 5: RuboCop**

Run: `bundle exec rubocop -a lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb && bundle exec rubocop lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb
git commit -m "Add writer lifecycle: close (pool stays warm), commit, delete, delete_all!"
```

---

## Task 6: Concurrency integration spec

**Files:**
- Create: `spec/support/thread_safety_helpers.rb`
- Create: `spec/integration/concurrency_spec.rb`
- Modify: `spec/spec_helper.rb`

**Interfaces:**
- Consumes: full writer.
- Produces: `ThreadSafetyHelpers#cyclic_barrier(count)` (tag `:thread_safety`); an integration spec proving no records are lost under a threaded pool.

- [ ] **Step 1: Write the thread-safety helper**

Create `spec/support/thread_safety_helpers.rb`:

```ruby
# frozen_string_literal: true

# Concurrency helpers included into example groups tagged :thread_safety.
module ThreadSafetyHelpers
  # Returns a lambda that blocks each caller until `count` callers have arrived,
  # so threads start their real work at the same moment.
  def cyclic_barrier(count)
    mutex = Mutex.new
    cond  = ConditionVariable.new
    arrived = 0
    lambda do
      mutex.synchronize do
        arrived += 1
        arrived >= count ? cond.broadcast : cond.wait(mutex)
      end
    end
  end
end
```

- [ ] **Step 2: Wire the helper into spec_helper**

Add to `spec/spec_helper.rb` inside `RSpec.configure`:

```ruby
  config.include ThreadSafetyHelpers, :thread_safety
```

- [ ] **Step 3: Write the failing concurrency spec**

Create `spec/integration/concurrency_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Writer concurrency', :integration, :solr_stub, :thread_safety do
  it 'delivers every record with a multi-thread writer pool' do
    received = Concurrent::AtomicFixnum.new(0)
    stub_request(:post, 'http://solr.test:8983/solr/core/update/json')
      .to_return do |req|
        received.increment(JSON.parse(req.body).length)
        { status: 200, body: '{}' }
      end

    writer = Traject::SolrPool::SolrJsonWriter.new(
      'solr.url' => 'http://solr.test:8983/solr/core',
      'solr_writer.batch_size' => 10,
      'solr_writer.thread_pool' => 4,
      'solr_pool.pool_size' => 4
    )

    200.times { |i| writer.put(Traject::Indexer::Context.new(output_hash: { 'id' => i.to_s })) }
    writer.close

    expect(received.value).to eq(200)
  end
end
```

- [ ] **Step 4: Run to verify it passes (behaviour already implemented)**

Run: `bundle exec rspec spec/integration/concurrency_spec.rb`
Expected: PASS. (This is an integration guard; the writer already implements the behaviour, so it should pass once wiring is correct. If it fails on lost records, that is a real thread-safety bug — STOP and debug with superpowers:systematic-debugging, do not weaken the assertion.)

- [ ] **Step 5: RuboCop**

Run: `bundle exec rubocop -a spec/integration/concurrency_spec.rb spec/support/thread_safety_helpers.rb && bundle exec rubocop spec/integration/concurrency_spec.rb spec/support/thread_safety_helpers.rb spec/spec_helper.rb`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add spec/support/thread_safety_helpers.rb spec/integration/concurrency_spec.rb spec/spec_helper.rb
git commit -m "Add concurrency integration spec proving no lost records under threaded pool"
```

---

## Task 7: Background-job (Sidekiq >= 8 / Active Job) integration spec

**Files:**
- Create: `spec/support/job_helpers.rb`
- Create: `spec/integration/background_job_spec.rb`
- Modify: `spec/spec_helper.rb`

**Interfaces:**
- Consumes: full writer; `sidekiq`, `active_job` (test-only).
- Produces: `JobHelpers` (tag `:background_jobs`) with a job that runs the writer; a spec proving the writer works inside a Sidekiq >= 8 worker and shares one pool across jobs.

- [ ] **Step 1: Write the job helper**

Create `spec/support/job_helpers.rb`:

```ruby
# frozen_string_literal: true

require 'sidekiq'
require 'sidekiq/testing'

# Helpers and job classes for the background-job integration spec. Included into
# any example group tagged :background_jobs. Sidekiq runs inline (enqueue =
# synchronous execution) so we exercise the worker path without Redis.
module JobHelpers
  def self.included(base)
    base.before { Sidekiq::Testing.inline! }
    base.after  { Sidekiq::Testing.fake! }
  end

  SOLR_URL = 'http://solr.jobs.test:8983/solr/core'

  class IndexJob
    include Sidekiq::Job

    def perform(id)
      writer = Traject::SolrPool::SolrJsonWriter.new(
        'solr.url' => SOLR_URL,
        'solr_writer.thread_pool' => 0,
        'solr_writer.batch_size' => 1
      )
      writer.put(Traject::Indexer::Context.new(output_hash: { 'id' => id }))
      writer.close
    end
  end

  def registry
    HttpConnectionPool::Registry.instance
  end
end
```

- [ ] **Step 2: Wire into spec_helper**

Add to `spec/spec_helper.rb`:

```ruby
  config.include JobHelpers, :background_jobs
```

- [ ] **Step 3: Write the failing spec**

Create `spec/integration/background_job_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Background job integration', :integration, :background_jobs, :solr_stub do
  before do
    stub_request(:post, 'http://solr.jobs.test:8983/solr/core/update/json')
      .to_return(status: 200, body: '{}')
  end

  it 'runs the pooled writer inside a Sidekiq job' do
    JobHelpers::IndexJob.perform_async('doc-1')
    expect(
      a_request(:post, 'http://solr.jobs.test:8983/solr/core/update/json')
    ).to have_been_made
  end

  it 'shares one pool across many sequential jobs against the same origin' do
    25.times { |i| JobHelpers::IndexJob.perform_async("doc-#{i}") }
    origins = registry.stats.map { |s| s[:origin] }
    expect(origins.count { |o| o == 'http://solr.jobs.test:8983' }).to eq(1)
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/integration/background_job_spec.rb`
Expected: PASS (2 examples). If Sidekiq 8 requires a Redis client even in inline mode at load, set `Sidekiq.configure_client`/`configure_server` no-ops in the helper or rescue the connection at load; keep the writer behaviour assertions intact.

- [ ] **Step 5: RuboCop**

Run: `bundle exec rubocop -a spec/support/job_helpers.rb spec/integration/background_job_spec.rb && bundle exec rubocop spec/support/job_helpers.rb spec/integration/background_job_spec.rb spec/spec_helper.rb`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add spec/support/job_helpers.rb spec/integration/background_job_spec.rb spec/spec_helper.rb
git commit -m "Add Sidekiq >= 8 background-job integration spec"
```

---

## Task 8: Zeitwerk and Rails compatibility integration specs

**Files:**
- Create: `spec/integration/zeitwerk_compliance_spec.rb`
- Create: `spec/integration/rails_compatibility_spec.rb`
- Modify: `.rubocop.yml` (exclude `RSpec/DescribeClass` for integration specs)

**Interfaces:**
- Consumes: the gem's file/constant layout; `zeitwerk`, `activesupport` (test-only).
- Produces: proof the layout eager-loads under Zeitwerk in a clean subprocess and coexists with activesupport.

- [ ] **Step 1: Exclude RSpec/DescribeClass for integration specs**

Add to `.rubocop.yml`:

```yaml
RSpec/DescribeClass:
  Exclude:
    - 'spec/integration/**/*'
```

- [ ] **Step 2: Write the Zeitwerk compliance spec**

Create `spec/integration/zeitwerk_compliance_spec.rb`. Because the gem lives under `lib/traject/` but only owns the `traject/solr_pool` subtree (traject itself owns `traject/`), the loader pushes `lib` and ignores everything except our files by ignoring the traject entry points. Simplest correct approach: push a loader rooted at `lib`, ignore `traject/solr_pool.rb` (entry) and `traject/solr_pool/version.rb`, and only assert our constants resolve.

```ruby
# frozen_string_literal: true

require 'spec_helper'

# Verifies our file/constant layout conforms to Zeitwerk naming so a host Rails
# app eager-loading in production never trips over it. The gem itself loads via
# plain require (traject convention) and takes no runtime Zeitwerk dependency.
#
# Subprocess: spec_helper already required the gem, so an in-process loader
# would no-op. A clean process exercises a real autoload.
RSpec.describe 'Zeitwerk compliance', :integration do
  let(:gem_root) { File.expand_path('../..', __dir__) }

  let(:probe) do
    <<~RUBY
      require 'zeitwerk'
      lib = File.join(#{gem_root.inspect}, 'lib')
      loader = Zeitwerk::Loader.new
      loader.push_dir(lib)
      # traject/ is owned by the traject gem; we only manage our subtree. Ignore
      # the entry file and version.rb (defines VERSION, not Version).
      loader.ignore(File.join(lib, 'traject', 'solr_pool.rb'))
      loader.ignore(File.join(lib, 'traject', 'solr_pool', 'version.rb'))
      # Everything else under lib/traject that is not ours must be ignored too;
      # our gem ships only the solr_pool subtree, so nothing else exists.
      loader.setup
      loader.eager_load
      %w[
        Traject::SolrPool::Connection
        Traject::SolrPool::SolrJsonWriter
      ].each { |c| Object.const_get(c) }
      print 'ZEITWERK_OK'
    RUBY
  end

  it 'eager-loads cleanly under a real Zeitwerk loader in a clean process' do
    expect(run_in_clean_process(probe)).to include('ZEITWERK_OK')
  end

  it 'reports no naming errors from Zeitwerk' do
    expect(run_in_clean_process(probe)).not_to match(/Zeitwerk::|NameError|expected file/)
  end

  def run_in_clean_process(source)
    require 'open3'
    out, status = Open3.capture2e('bundle', 'exec', 'ruby', '-e', source, chdir: gem_root)
    raise "probe failed (#{status.exitstatus}):\n#{out}" unless status.success?

    out
  end
end
```

- [ ] **Step 3: Run the Zeitwerk spec**

Run: `bundle exec rspec spec/integration/zeitwerk_compliance_spec.rb`
Expected: PASS. If it fails because `traject/solr_pool.rb` requires `traject` (pulling the whole traject tree into the loader's managed dir), add `loader.do_not_eager_load` for non-owned paths or push_dir only conceptually — the pragmatic fix is: since Zeitwerk manages `lib`, and traject is loaded via `require 'traject'` before setup, `require 'traject'` inside our files is fine; the loader only autoloads files under `lib` matching unresolved constants. If traject's own files under a *different* gem dir are not under our `lib`, they are not managed. This should pass as written; if a NameError names a traject constant, add that file to `loader.ignore` and note it in a comment.

- [ ] **Step 4: Write the Rails-compatibility spec**

Create `spec/integration/rails_compatibility_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'active_support'
require 'active_support/core_ext/object/blank'

# Confirms the writer coexists with activesupport loaded (as in a Rails app) and
# behaves inside a plain service object. No full Rails boot; activesupport only.
RSpec.describe 'Rails compatibility', :integration, :solr_stub do
  it 'loads alongside activesupport without redefining core behaviour' do
    expect(''.blank?).to be(true)
    expect(defined?(Traject::SolrPool::SolrJsonWriter)).to eq('constant')
  end

  it 'indexes from a Rails-style service object' do
    stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
    service = Class.new do
      def call
        w = Traject::SolrPool::SolrJsonWriter.new(
          'solr.url' => 'http://solr.test:8983/solr/core',
          'solr_writer.thread_pool' => 0, 'solr_writer.batch_size' => 1
        )
        w.put(Traject::Indexer::Context.new(output_hash: { 'id' => 'svc-1' }))
        w.close
      end
    end
    service.new.call
    expect(stub).to have_been_requested
  end
end
```

- [ ] **Step 5: Run the Rails spec**

Run: `bundle exec rspec spec/integration/rails_compatibility_spec.rb`
Expected: PASS (2 examples).

- [ ] **Step 6: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: all green, RuboCop clean.

- [ ] **Step 7: Commit**

```bash
git add spec/integration/zeitwerk_compliance_spec.rb spec/integration/rails_compatibility_spec.rb .rubocop.yml
git commit -m "Add Zeitwerk and Rails compatibility integration specs"
```

---

## Task 9: Documentation and Rakefile

**Files:**
- Modify: `README.md`
- Modify: `Rakefile`
- Create: `docs/usage.md`

**Interfaces:**
- Produces: user-facing docs for `writer_class_name` usage, settings, the temporary edge-traject dependency, and a `bundle:audit` CI wiring.

- [ ] **Step 1: Wire bundler-audit into the default Rake task**

Replace `Rakefile` contents:

```ruby
# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'bundler/audit/task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

task ci: %i[bundle:audit:check rubocop spec]
task default: :ci
```

- [ ] **Step 2: Verify the Rake tasks run**

Run: `bundle exec rake -T`
Expected: lists `spec`, `rubocop`, `bundle:audit:check`, `ci`, `default`. Then run `bundle exec rake ci` — expected green (audit offline, RuboCop clean, RSpec green).

- [ ] **Step 3: Rewrite README.md**

Replace the placeholder README with real content. Required sections (H1 `# Traject::SolrPool`, then): what it is (pooled drop-in Solr JSON writer), installation, the temporary edge-traject dependency note and how to remove it, `writer_class_name` usage example, the settings table (copy the settings section from the design spec), dropped `solr_json_writer.*` settings note, thread-safety/Sidekiq/Zeitwerk statement, development (`bundle exec rake ci`), and the never-push policy under contributing. Use single-quoted Ruby in fenced `ruby` blocks. Example usage block to include:

````markdown
```ruby
require 'traject/solr_pool'

settings do
  provide 'writer_class_name', 'Traject::SolrPool::SolrJsonWriter'
  provide 'solr.url', 'http://localhost:8983/solr/my_core'
  provide 'solr_writer.thread_pool', 4
  provide 'solr_pool.pool_size', 5
end
```
````

- [ ] **Step 4: Write docs/usage.md**

Create `docs/usage.md` with the full settings reference (the table from the design spec), the error-handling behaviour (`BadHttpResponse`, default skippable exceptions), and the pool-stays-warm-on-close note. One H1, sentence-case headings, fenced code with language tags.

- [ ] **Step 5: RuboCop on Rakefile**

Run: `bundle exec rubocop Rakefile`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add README.md Rakefile docs/usage.md
git commit -m "Document usage and settings; wire bundler-audit into rake ci"
```

---

## Self-Review

**Spec coverage:**
- Goal (pooled drop-in writer) → Tasks 2–5. ✓
- Reusable Connection seam → Task 2. ✓
- Settings vocabulary + `solr_pool.pool_size` → Task 3. ✓
- Output path + batch fallback → Task 4. ✓
- Error mapping (`BadHttpResponse` + http.rb-native skippable list) → Task 4. ✓
- `commit`/`delete`/`delete_all!`, close leaves pool warm → Task 5. ✓
- Thread safety → Task 6. ✓
- Sidekiq >= 8 → Task 7. ✓
- Zeitwerk + Rails → Task 8. ✓
- Test-only dep grouping, single-quote RuboCop → Task 1 (config already set in brainstorming commit). ✓
- Docs + bundler-audit → Task 9. ✓
- Temporary edge-traject dependency documented → Tasks 1 (gemspec NOTE) + 9 (README). ✓

**Placeholder scan:** No TBD/TODO left as work items; the gemspec/README "TODO" strings are explicitly replaced in Tasks 1 and 9.

**Type consistency:** `Connection#post(path, body:)` / `#get(path, params:)` defined in Task 2 and consumed identically in Tasks 4–5. `request_path` (Task 3) used in Tasks 4–5. `BadHttpResponse#response` is an http.rb response (`#code`/`#to_s`) consistently. `skipped_record_count`, `MaxSkippedRecordsExceeded` names consistent across Tasks 4–5.

**Known verification points flagged inline (not placeholders):** `Registry.close_all` vs `reset!` (Task 1 Step 7), http.rb `params: {}` on GET (Task 2 Step 5), Sidekiq 8 inline load without Redis (Task 7 Step 4), Zeitwerk ignore set (Task 8 Step 3). Each has a concrete fallback.
