# Connection Health Check, Release Automation, and Docs Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a HEAD-based health-check API (`head`/`ping`/`ready?`) to the reusable `Connection` seam with writer delegation, wire up tag-triggered OIDC release automation with published-gem checksums and version-bump tasks, and do a rigorous documentation pass.

**Architecture:** `Connection` gains a generic `head` verb plus `ping` (raw response, raises on transport failure) and `ready?` (boolean liveness — any HTTP response means reachable, only transport errors mean down). The writer delegates via thin wrappers using a configurable, derived ping path. Release infrastructure mirrors the sibling `http_connection_pool` gem exactly. Docs get worked examples and durable cross-gem references.

**Tech Stack:** Ruby 3.3+ (MRI), RSpec, WebMock, http.rb 6.x (llhttp), `http_connection_pool`, traject 3.9, concurrent-ruby.

## Global Constraints

- All non-interpolated strings use single quotes.
- Every Ruby file begins with `# frozen_string_literal: true`.
- No apostrophes in RSpec `it`/`describe`/`context` description strings (Ruby SyntaxError with single quotes) — rephrase or use the parent-class-value wording.
- Comments explain *why*, never *what*. No top-level what-comments.
- `bundle exec rubocop` must be clean before every commit; `rake ci` (bundle:audit:check → rubocop → spec) must be green before finishing.
- Never print credential material (auth header, header values) in any log line, `inspect`, `to_s`, or error message.
- `gem push`, `git push`, and pushing a tag are **user-only** actions. Tasks and workflows may print the commands but never run them. The assistant may `git commit` but never `git push`.
- **All implementer and reviewer subagents MUST run on Opus (Opus 4.8).** No Sonnet/Haiku for any task in this plan.
- Health-check requests use **HEAD** (no body to drain → keeps the pooled persistent socket clean; http.rb calls `finish_response` for HEAD verbs).
- `ready?` returns `true` for ANY HTTP status (incl. 405/404); `false` ONLY on transport failure. It never raises. `ping` returns the raw response and DOES raise transport errors.

---

### Task 1: Connection health-check API (`head`, `ping`, `ready?`)

**Files:**
- Modify: `lib/traject/solr_pool/connection.rb`
- Test: `spec/traject/solr_pool/connection_spec.rb`

**Interfaces:**
- Consumes: existing `@adapter.with_connection { |conn| ... }` seam; `conn` is an `HTTP::Session` responding to `head`/`get`/`post` and the `timeout(n)` chainable.
- Produces:
  - `Connection::TRANSPORT_ERRORS` → frozen `Array` of exception classes.
  - `Connection#head(path, timeout: nil)` → `HTTP::Response`.
  - `Connection#ping(path, timeout: nil)` → `HTTP::Response`; raises on transport failure.
  - `Connection#ready?(path, timeout: nil)` → `true`/`false`; never raises.

- [ ] **Step 1: Write the failing tests**

Append to `spec/traject/solr_pool/connection_spec.rb`, inside the top-level `describe` block (before the final `end`):

```ruby
  describe 'health check' do
    it 'issues a HEAD to the given path and returns the response' do
      stub = stub_request(:head, 'http://solr.test:8983/solr/core/admin/ping').to_return(status: 200)
      resp = connection.head('/solr/core/admin/ping')
      expect(stub).to have_been_requested
      expect(resp.status).to eq(200)
    end

    it 'ping returns the raw response object with its status' do
      stub_request(:head, 'http://solr.test:8983/ping').to_return(status: 503)
      expect(connection.ping('/ping').status).to eq(503)
    end

    it 'ping propagates a transport error' do
      stub_request(:head, 'http://solr.test:8983/ping').to_raise(HTTP::ConnectionError)
      expect { connection.ping('/ping') }.to raise_error(HTTP::ConnectionError)
    end

    it 'ready? is true for a 200' do
      stub_request(:head, 'http://solr.test:8983/ping').to_return(status: 200)
      expect(connection.ready?('/ping')).to be(true)
    end

    it 'ready? is true for a 405 because the server is reachable' do
      stub = stub_request(:head, 'http://solr.test:8983/ping').to_return(status: 405)
      expect(connection.ready?('/ping')).to be(true)
      expect(stub).to have_been_requested
    end

    it 'ready? is true for a 404 because the server is reachable' do
      stub = stub_request(:head, 'http://solr.test:8983/ping').to_return(status: 404)
      expect(connection.ready?('/ping')).to be(true)
      expect(stub).to have_been_requested
    end

    it 'ready? is false on a transport error and does not raise' do
      stub_request(:head, 'http://solr.test:8983/ping').to_raise(HTTP::ConnectionError)
      expect(connection.ready?('/ping')).to be(false)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/traject/solr_pool/connection_spec.rb -e 'health check'`
Expected: FAIL with `NoMethodError: undefined method 'head'` (and `ping`/`ready?`).

- [ ] **Step 3: Implement the methods**

In `lib/traject/solr_pool/connection.rb`, add the constant just inside `class Connection` (after the `Options` struct, before `attr_reader :origin`):

```ruby
      # Transport-level failures that mean the server is unreachable. A returned
      # HTTP response of ANY status (2xx/4xx/5xx) is NOT in this set — it proves
      # the server answered. Kept independent of the writer's skippable list.
      TRANSPORT_ERRORS = [
        HTTP::TimeoutError,
        HttpConnectionPool::TimeoutError,
        HTTP::ConnectionError,
        SocketError,
        Errno::ECONNREFUSED
      ].freeze
```

Add these methods after the existing `get` method (before `release`):

```ruby
      def head(path, timeout: nil)
        @adapter.with_connection do |conn|
          client = timeout ? conn.timeout(timeout) : conn
          client.head(path)
        end
      end

      # Raw health probe: returns the HTTP::Response (any status) so callers can
      # inspect it. Raises on transport failure. HEAD has no body to drain, so
      # it leaves the pooled persistent socket clean for reuse.
      def ping(path, timeout: nil)
        head(path, timeout: timeout)
      end

      # Liveness predicate. Any HTTP response means reachable -> true. Only a
      # transport failure means down -> false. Never raises.
      def ready?(path, timeout: nil)
        !ping(path, timeout: timeout).nil?
      rescue *TRANSPORT_ERRORS
        false
      end
```

Add `require 'http'` at the top of the file only if it is not already required transitively — `http_connection_pool` already loads `http`, and the constants `HTTP::ConnectionError` etc. resolve, so no new require is expected. Verify by running the tests.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/traject/solr_pool/connection_spec.rb`
Expected: PASS (all existing + 7 new examples).

- [ ] **Step 5: RuboCop**

Run: `bundle exec rubocop lib/traject/solr_pool/connection.rb spec/traject/solr_pool/connection_spec.rb`
Expected: no offenses. (If `Metrics/MethodLength` or similar fires, the methods are already minimal — do not disable; report back.)

- [ ] **Step 6: Commit**

```bash
git add lib/traject/solr_pool/connection.rb spec/traject/solr_pool/connection_spec.rb
git commit -m "Add Connection#head/ping/ready? HEAD-based health check"
```

---

### Task 2: Writer delegation and configurable ping path

**Files:**
- Modify: `lib/traject/solr_pool/solr_json_writer.rb`
- Test: `spec/traject/solr_pool/solr_json_writer_spec.rb`

**Interfaces:**
- Consumes: `Connection#ping(path, timeout:)` and `Connection#ready?(path, timeout:)` from Task 1; existing `@solr_update_url` (String, credentials already stripped) set in `configure_pools`; existing `configure_from_settings` orchestration method.
- Produces:
  - `SolrJsonWriter#ping(timeout: nil)` → delegates to `connection.ping(@ping_path, timeout: timeout || @ping_timeout)`.
  - `SolrJsonWriter#ready?(timeout: nil)` → delegates to `connection.ready?(@ping_path, timeout: timeout || @ping_timeout)`.
  - New settings: `solr_writer.ping_path` (String, default derived), `solr_writer.ping_timeout` (Integer seconds, default `5`).

- [ ] **Step 1: Write the failing tests**

Append to `spec/traject/solr_pool/solr_json_writer_spec.rb`, before the final `end` of the top-level `describe`:

```ruby
  describe 'health check' do
    it 'derives the ping path as the core admin/ping from solr.url' do
      stub = stub_request(:head, 'http://solr.test:8983/solr/core/admin/ping').to_return(status: 200)
      writer('solr_writer.thread_pool' => 0).ready?
      expect(stub).to have_been_requested
    end

    it 'derives the ping path from solr.update_url' do
      stub = stub_request(:head, 'http://solr.test:8983/solr/core/admin/ping').to_return(status: 200)
      described_class.new('solr.update_url' => 'http://solr.test:8983/solr/core/update').ready?
      expect(stub).to have_been_requested
    end

    it 'honours an explicit solr_writer.ping_path' do
      stub = stub_request(:head, 'http://solr.test:8983/health').to_return(status: 200)
      writer('solr_writer.thread_pool' => 0, 'solr_writer.ping_path' => '/health').ready?
      expect(stub).to have_been_requested
    end

    it 'ready? is true when Solr answers and false when unreachable' do
      stub_request(:head, 'http://solr.test:8983/solr/core/admin/ping')
        .to_return(status: 200).then.to_raise(HTTP::ConnectionError)
      w = writer('solr_writer.thread_pool' => 0)
      expect(w.ready?).to be(true)
      expect(w.ready?).to be(false)
    end

    it 'ping returns the raw response for status inspection' do
      stub_request(:head, 'http://solr.test:8983/solr/core/admin/ping').to_return(status: 503)
      expect(writer('solr_writer.thread_pool' => 0).ping.status).to eq(503)
    end

    it 'defaults the ping timeout to 5 seconds' do
      stub_request(:head, 'http://solr.test:8983/solr/core/admin/ping').to_return(status: 200)
      w = writer('solr_writer.thread_pool' => 0)
      allow(w.connection).to receive(:ready?).and_call_original
      w.ready?
      expect(w.connection).to have_received(:ready?).with(anything, timeout: 5)
    end

    it 'passes an explicit ping timeout through' do
      stub_request(:head, 'http://solr.test:8983/solr/core/admin/ping').to_return(status: 200)
      w = writer('solr_writer.thread_pool' => 0, 'solr_writer.ping_timeout' => 2)
      allow(w.connection).to receive(:ping).and_call_original
      w.ping
      expect(w.connection).to have_received(:ping).with(anything, timeout: 2)
    end

    it 'sends the ping with the auth header and a credential-free path' do
      stub = stub_request(:head, 'http://solr.test:8983/solr/core/admin/ping')
             .with(headers: { 'Authorization' => 'Basic dXNlcjpzZWNyZXQ=' })
             .to_return(status: 200)
      described_class.new('solr.url' => 'http://user:secret@solr.test:8983/solr/core',
                          'solr_writer.thread_pool' => 0).ready?
      expect(stub).to have_been_requested
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/traject/solr_pool/solr_json_writer_spec.rb -e 'health check'`
Expected: FAIL with `NoMethodError: undefined method 'ready?'`.

- [ ] **Step 3: Implement delegation and configuration**

In `lib/traject/solr_pool/solr_json_writer.rb`:

Add the two public methods after the existing `delete_all!` method (before `private`):

```ruby
      def ping(timeout: nil)
        connection.ping(@ping_path, timeout: timeout || @ping_timeout)
      end

      def ready?(timeout: nil)
        connection.ready?(@ping_path, timeout: timeout || @ping_timeout)
      end
```

Add `configure_ping` to the orchestration. Change `configure_from_settings`:

```ruby
      def configure_from_settings
        configure_skipped
        configure_batching
        configure_pools
        configure_commit
        configure_ping
      end
```

Add the private method (place it after `configure_commit`):

```ruby
      def configure_ping
        @ping_path    = @settings['solr_writer.ping_path'] || derive_ping_path
        @ping_timeout = (@settings['solr_writer.ping_timeout'] || 5).to_i
      end

      # Derive <core>/admin/ping from the update URL path by stripping a
      # trailing /update or /update/json segment. Falls back to appending
      # /admin/ping to the whole path when no update segment is present.
      def derive_ping_path
        path = URI.parse(@solr_update_url).path
        base = path.sub(%r{/update(/json)?/?\z}, '')
        base = path if base.empty?
        "#{base}/admin/ping"
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: PASS (all existing + 8 new examples).

- [ ] **Step 5: RuboCop**

Run: `bundle exec rubocop lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/traject/solr_pool/solr_json_writer.rb spec/traject/solr_pool/solr_json_writer_spec.rb
git commit -m "Delegate ping/ready? on the writer with a derived ping_path"
```

---

### Task 3: Version-bump Rake tasks

**Files:**
- Create: `tasks/version_bumper.rb`
- Create: `spec/tasks/version_bumper_spec.rb`
- Modify: `Rakefile`

**Interfaces:**
- Consumes: `Traject::SolrPool::VERSION` string in `lib/traject/solr_pool/version.rb`.
- Produces: `VersionBumper.next(current, level)` → next version String; `VersionBumper::LEVELS` → `%i[major minor patch]`; `rake bump:patch|minor|major` tasks.

- [ ] **Step 1: Write the failing test**

Create `spec/tasks/version_bumper_spec.rb`:

```ruby
# frozen_string_literal: true

require_relative '../../tasks/version_bumper'

RSpec.describe VersionBumper do
  describe '.next' do
    it 'bumps the patch segment' do
      expect(described_class.next('0.1.0', :patch)).to eq('0.1.1')
    end

    it 'bumps the minor segment and resets patch' do
      expect(described_class.next('0.1.5', :minor)).to eq('0.2.0')
    end

    it 'bumps the major segment and resets minor and patch' do
      expect(described_class.next('1.4.2', :major)).to eq('2.0.0')
    end

    it 'accepts a string level' do
      expect(described_class.next('0.1.0', 'patch')).to eq('0.1.1')
    end

    it 'raises on an unknown level' do
      expect { described_class.next('0.1.0', :nope) }.to raise_error(ArgumentError)
    end

    it 'raises on a malformed version' do
      expect { described_class.next('0.1', :patch) }.to raise_error(ArgumentError)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/tasks/version_bumper_spec.rb`
Expected: FAIL with `cannot load such file -- .../tasks/version_bumper`.

- [ ] **Step 3: Implement the version bumper**

Create `tasks/version_bumper.rb` (kept out of `lib/` so it is never packaged — `spec.files` globs exclude it):

```ruby
# frozen_string_literal: true

# Pure semantic-version arithmetic for the `bump:*` Rake tasks. Kept out of
# lib/ so it is never packaged into the gem.
module VersionBumper
  LEVELS = %i[major minor patch].freeze

  def self.next(current, level)
    level = level.to_sym
    validate_level!(level)
    parts = parse_version!(current)
    compute_next(parts, level)
  end

  def self.validate_level!(level)
    return if LEVELS.include?(level)

    raise ArgumentError, "unknown level #{level.inspect}, expected one of #{LEVELS.inspect}"
  end
  private_class_method :validate_level!

  def self.parse_version!(current)
    parts = current.split('.')
    valid = parts.length == 3 && parts.all? { |p| p.match?(/\A\d+\z/) }
    raise ArgumentError, "malformed version #{current.inspect}, expected MAJOR.MINOR.PATCH" unless valid

    parts.map(&:to_i)
  end
  private_class_method :parse_version!

  def self.compute_next(parts, level)
    major, minor, patch = parts
    case level
    when :major then "#{major + 1}.0.0"
    when :minor then "#{major}.#{minor + 1}.0"
    when :patch then "#{major}.#{minor}.#{patch + 1}"
    end
  end
  private_class_method :compute_next
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/tasks/version_bumper_spec.rb`
Expected: PASS (6 examples).

- [ ] **Step 5: Wire the bump tasks into the Rakefile**

In `Rakefile`, add the require near the other requires (after `require 'bundler/audit/task'`):

```ruby
require_relative 'tasks/version_bumper'
```

Add the following after the `task default: :ci` line:

```ruby
VERSION_FILE = 'lib/traject/solr_pool/version.rb'

namespace :bump do
  VersionBumper::LEVELS.each do |level|
    desc "Bump the #{level} version and print the release commands"
    task(level) { bump_version(level) }
  end
end

def bump_version(level)
  contents = File.read(VERSION_FILE)
  current  = contents[/VERSION = '([^']+)'/, 1]
  raise "could not find VERSION in #{VERSION_FILE}" unless current

  bumped = VersionBumper.next(current, level)
  File.write(VERSION_FILE, contents.sub(/VERSION = '[^']+'/, "VERSION = '#{bumped}'"))
  puts "Bumped #{current} -> #{bumped}"

  puts <<~NEXT
    Next steps (run these yourself):
      git add #{VERSION_FILE}
      git commit -m 'Release v#{bumped}'
      git tag v#{bumped}
      git push && git push --tags
  NEXT
end
```

- [ ] **Step 6: Verify the tasks are listed and do not run destructive actions**

Run: `bundle exec rake -T bump`
Expected: three tasks listed (`bump:major`, `bump:minor`, `bump:patch`) with their descriptions. Do NOT run any `bump:*` task (it would edit `version.rb`).

- [ ] **Step 7: RuboCop**

Run: `bundle exec rubocop tasks/version_bumper.rb spec/tasks/version_bumper_spec.rb Rakefile`
Expected: no offenses. If `Style/Documentation` fires on the module, the existing module comment satisfies it; if `Metrics/MethodLength` fires on `bump_version`, it is 12 lines — under the limit.

Note: `spec/tasks/` is under `spec/**/*`, already covered by the `Metrics/BlockLength` and RSpec excludes. No `.rubocop.yml` change needed. If RuboCop complains that `spec/tasks/version_bumper_spec.rb` describes a class outside `spec/integration`, `RSpec/DescribeClass` is satisfied because it describes `VersionBumper` directly.

- [ ] **Step 8: Commit**

```bash
git add tasks/version_bumper.rb spec/tasks/version_bumper_spec.rb Rakefile
git commit -m "Add rake bump:patch/minor/major version tasks"
```

---

### Task 4: Build checksum task, release workflow, and gitignore

**Files:**
- Modify: `Rakefile`
- Modify: `.gitignore`
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `bundler/gem_tasks` `build` task (already required in `Rakefile`); `Traject::SolrPool::VERSION`; the `bump:*` tasks from Task 3 (independent, not called here).
- Produces: `rake build:checksum` task writing `checksums/traject-solr_pool-<version>.{sha256,sha512}`; `release.yml` triggered on `v*.*.*` tags.

- [ ] **Step 1: Add the build:checksum task to the Rakefile**

In `Rakefile`, add after the `bump` namespace block (order among top-level tasks does not matter). Note `bundler/gem_tasks` is already required:

```ruby
# `bundler/gem_tasks` provides `build` (into pkg/). We extend it to record
# SHA-256 and SHA-512 digests of the built .gem in the standard
# `sha256sum -c` / `sha512sum -c` format. These describe THIS build's artifact;
# the release workflow runs this against the exact gem it just published and
# attaches the digests to the GitHub Release. .gem builds are not byte-stable
# across zlib/RubyGems versions, so checksums are recorded per published
# artifact rather than committed to the repo and byte-compared in CI.
namespace :build do
  desc 'Build the gem, then write SHA-256 and SHA-512 checksums to checksums/'
  task :checksum do
    require 'digest'
    require_relative 'lib/traject/solr_pool/version'

    gem_path = File.join('pkg', "traject-solr_pool-#{Traject::SolrPool::VERSION}.gem")
    Rake::Task['build'].invoke unless File.exist?(gem_path)

    write_checksum(gem_path, Digest::SHA256, 'sha256')
    write_checksum(gem_path, Digest::SHA512, 'sha512')

    # bundler/gem_tasks' build writes its own raw-format `<name>.gem.sha512`
    # (digest only, no filename). Remove it so checksums/ holds exactly one
    # sha256 and one sha512, both in the standard `<digest>  <file>` format.
    redundant = File.join('checksums', "#{File.basename(gem_path)}.sha512")
    rm_f redundant
  end
end

def write_checksum(gem_path, digest_class, extension)
  mkdir_p 'checksums'
  digest = digest_class.file(gem_path).hexdigest
  basename = File.basename(gem_path, '.gem')
  out = File.join('checksums', "#{basename}.#{extension}")
  File.write(out, "#{digest}  #{File.basename(gem_path)}\n")
  puts "#{extension}: #{digest}  -> #{out}"
end
```

- [ ] **Step 2: Add checksums to .gitignore**

In `.gitignore`, add below the existing `*.gem` line:

```
/checksums/
```

- [ ] **Step 3: Verify build:checksum produces valid files**

Run: `bundle exec rake build:checksum`
Expected: builds `pkg/traject-solr_pool-0.1.0.gem` and prints two lines (`sha256: ...`, `sha512: ...`). Then verify format:

Run: `cd checksums && shasum -a 256 -c traject-solr_pool-0.1.0.sha256 && shasum -a 512 -c traject-solr_pool-0.1.0.sha512 && cd ..`
Expected: both print `traject-solr_pool-0.1.0.gem: OK`.

Then confirm nothing is staged for commit from these artifacts:

Run: `git status --porcelain`
Expected: shows only `.gitignore` and `Rakefile` as modified, and `.github/` untracked once Step 4 is done — NOT `pkg/` or `checksums/`.

- [ ] **Step 4: Create the release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*.*.*']

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: write   # create the GitHub Release and attach assets
      id-token: write   # OIDC token for RubyGems Trusted Publishing
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.4'
          bundler-cache: true

      - name: Verify tag matches gem version
        run: |
          gem_version="$(ruby -Ilib -r traject/solr_pool/version \
            -e 'print Traject::SolrPool::VERSION')"
          tag_version="${GITHUB_REF_NAME#v}"
          if [ "$gem_version" != "$tag_version" ]; then
            echo "Tag $GITHUB_REF_NAME does not match VERSION $gem_version" >&2
            exit 1
          fi

      # Re-run the specs (not RuboCop) before publishing. A tag push does not
      # trigger ci.yml, and dependencies resolve fresh (Gemfile.lock is
      # gitignored), so this guards against a broken artifact under a newer
      # in-range dependency the last main CI run never saw. A yanked version
      # number can never be reused, so publishing red is uniquely costly.
      - run: bundle exec rake spec

      # Builds via `rake release` and pushes over OIDC. It leaves the exact
      # published .gem in pkg/, which the steps below checksum and attach.
      - uses: rubygems/release-gem@v1

      # Record digests of the artifact that was actually published (pkg/*.gem
      # from the step above). .gem builds are not byte-stable across
      # zlib/RubyGems versions, so the published gem is the source of truth
      # rather than a repo-committed checksum compared against a fresh build.
      - name: Checksum the published gem
        run: bundle exec rake build:checksum

      - name: Create GitHub Release with gem and checksums
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" \
            --title "$GITHUB_REF_NAME" \
            --generate-notes \
            pkg/traject-solr_pool-*.gem \
            checksums/traject-solr_pool-*.sha256 \
            checksums/traject-solr_pool-*.sha512
```

- [ ] **Step 5: Verify the tag-verify step logic locally**

Run: `ruby -Ilib -r traject/solr_pool/version -e 'print Traject::SolrPool::VERSION'`
Expected: prints `0.1.0` (proves the `-r` path in the workflow resolves).

- [ ] **Step 6: RuboCop and clean the build artifacts**

Run: `bundle exec rubocop Rakefile`
Expected: no offenses. If `Metrics/AbcSize`/`MethodLength` fires on the checksum task block, it matches the proven sibling task; report rather than disable.

Remove the local build artifacts so they are not accidentally added (they are gitignored, but keep the tree clean):

Run: `rm -rf pkg checksums`

- [ ] **Step 7: Commit**

```bash
git add Rakefile .gitignore .github/workflows/release.yml
git commit -m "Add release.yml, build:checksum task, and checksums gitignore"
```

---

### Task 5: Documentation pass

**Files:**
- Modify: `README.md`
- Modify: `docs/usage.md`
- Modify: `CLAUDE.md`
- Modify: `docs/skills/README.md`
- Modify: `docs/agents/README.md`

**Interfaces:**
- Consumes: the public API from Tasks 1–2 (`ping`/`ready?` on writer and `Connection`, `solr_writer.ping_path`/`ping_timeout` settings) and the Rake/release infra from Tasks 3–4.
- Produces: no code; documentation only. No commit gate on tests, but `rake ci` must stay green (docs edits do not touch code).

- [ ] **Step 1: Add the health-check section to `docs/usage.md`**

Insert a new `## Health check` section after the `## Registering the writer` section (before `## Settings`):

````markdown
## Health check

Check whether Solr is reachable before indexing. The writer delegates to the
pooled connection and issues a **HEAD** request (no body to drain, so the
persistent socket stays clean for reuse):

```ruby
writer = Traject::SolrPool::SolrJsonWriter.new(settings)

# Boolean liveness guard.
abort 'Solr is down' unless writer.ready?

# Raw response when you need the status code or headers.
resp = writer.ping
puts resp.status
```

### What `ready?` means

- `ready?` returns `true` for **any** HTTP status the server returns —
  including `405 Method Not Allowed` (some Solr `PingRequestHandler` versions
  reject HEAD) and `404`. Any HTTP response proves the server process answered
  and is reachable.
- `ready?` returns `false` **only** on a transport failure: connection refused,
  read/connect timeout, DNS failure, or socket error. It never raises.
- To distinguish "reachable but returned 405/404/5xx" from "reachable and
  healthy", use `ping` and inspect `response.status` yourself — `ready?`
  deliberately does not make that distinction.

The health-check endpoint defaults to the core ping handler
(`<core>/admin/ping`), derived from the Solr URL. Override it with
`solr_writer.ping_path`. The request timeout defaults to 5 seconds
(`solr_writer.ping_timeout`) so a hung server fails fast.

### Reusing the pool from another class

The same pooled connection is reusable outside the writer — e.g. from a future
reader or a health-check daemon. Prefer handing out the writer's connection:

```ruby
conn = writer.connection
conn.ready?('/solr/core/admin/ping')
conn.get('/solr/core/select', params: { q: '*:*' })
```

Or resolve the pool straight from the registry. Pools are keyed by
`(origin, options)`, so the SAME origin and options return the SAME pool the
writer uses; different options (e.g. different credentials) get a separate pool
by design:

```ruby
pool = HttpConnectionPool::Registry.instance.pool_for(
  'http://localhost:8983',
  size: 5,
  auth: 'Basic dXNlcjpwYXNz'  # must match the writer's options to share its pool
)
pool.with { |conn| conn.head('/solr/my_core/admin/ping') }
```

`HttpConnectionPool::Registry.instance.stats` returns an `Array<Hash>` (one
entry per pool) and only proves a pool object exists locally — it does NOT
prove Solr is reachable. Use `ready?` for liveness.
````

- [ ] **Step 2: Add the two new settings rows to the `docs/usage.md` table**

In the settings table in `docs/usage.md`, add these rows after the
`solr_writer.pool_timeout` row:

```markdown
| `solr_writer.ping_path` | `<core>/admin/ping` derived from the Solr URL | Relative request path for `ready?`/`ping` health checks |
| `solr_writer.ping_timeout` | `5` | Per-request read timeout (seconds) for the health check, so a hung server fails fast |
```

- [ ] **Step 3: Add a health-check quick example to `README.md`**

In `README.md`, after the `## Usage` registration example, add:

````markdown
### Health check

```ruby
writer = Traject::SolrPool::SolrJsonWriter.new(settings)
abort 'Solr unreachable' unless writer.ready?
```

`ready?` returns `true` for any HTTP response (the server answered — including
`405`/`404`), and `false` only on a transport failure (refused/timeout/DNS). It
uses a HEAD request so the pooled persistent connection stays clean for reuse.
Use `writer.ping` for the raw response. Configure the endpoint with
`solr_writer.ping_path` (default `<core>/admin/ping`) and the timeout with
`solr_writer.ping_timeout` (default 5s). See [docs/usage.md](docs/usage.md) for
the full reference, including reusing the pool from another class.
````

- [ ] **Step 4: Add a Releasing section to `README.md`**

In `README.md`, add near the end (before any license section, or at the end if none):

````markdown
## Releasing

Releases are published to RubyGems via OIDC Trusted Publishing on a version
tag — no API key is stored. The maintainer:

1. Bumps the version: `rake bump:patch` (or `:minor` / `:major`). This edits
   `lib/traject/solr_pool/version.rb` and prints the next commands.
2. Commits and tags: `git commit -am 'Release vX.Y.Z' && git tag vX.Y.Z`.
3. Pushes the tag: `git push && git push --tags`.

Pushing the `v*.*.*` tag triggers `.github/workflows/release.yml`, which
verifies the tag matches `Traject::SolrPool::VERSION`, re-runs the specs,
publishes the gem, and creates a GitHub Release with the gem and its SHA-256 /
SHA-512 checksums attached. `gem push` and `git push` are maintainer actions;
CI never pushes on its own.
````

- [ ] **Step 5: Fix the cross-gem references in `docs/skills/README.md`**

In `docs/skills/README.md`, replace the section that begins
`## Reusable from the sibling` (the relative-path reference) so it reads:

```markdown
## Reusable from the sibling `http_connection_pool` gem

`http_connection_pool` is a runtime dependency, so its skill docs ship with it.
Read them either on GitHub or in the installed gem:

- GitHub: <https://github.com/bbarberBPL/http_connection_pool/tree/main/docs/skills>
- Locally: `bundle show http_connection_pool` (or `gem which
  http_connection_pool`) prints the install path; the skills live under
  `docs/skills/` there.

These transfer with minor path changes:

- `dependency-audit` — security sweep that verifies every advisory/version claim
  against primary sources before recommending a change. Reuse verbatim whenever
  a dependency floor changes.
- `memory-leak-audit` — drives churn and measures retention with
  `ObjectSpace`/`GC` rather than reading code. Adapt the churn driver to enqueue
  writer batches / background jobs against a WebMock-stubbed Solr.
```

Also update the `edge-traject-cutover` "done" note if it still references the
sibling by relative path (leave its content otherwise intact).

- [ ] **Step 6: Fix the cross-gem references in `docs/agents/README.md`**

In `docs/agents/README.md`, find the line that points at the sibling gem's
agents by relative path (`../../../http_connection_pool/docs/agents` or similar)
and replace the pointer with:

```markdown
The sibling `http_connection_pool` gem defines reusable review agents. Since it
is a runtime dependency, read them on GitHub at
<https://github.com/bbarberBPL/http_connection_pool/tree/main/docs/agents> or
locally via `bundle show http_connection_pool` (the agents live under
`docs/agents/` in the install path).
```

Leave the individual agent descriptions (`concurrency-spec-reviewer`,
`dependency-security-auditor`, `memory-leak-auditor`) intact.

- [ ] **Step 7: Update `CLAUDE.md`**

In `CLAUDE.md`:

1. In the Rake Tasks table, add these rows:

```markdown
| `rake build:checksum`     | Build, then write SHA-256 + SHA-512 to `checksums/` (gitignored) |
| `rake bump:patch`         | Bump patch version in version.rb, print release commands |
| `rake bump:minor`         | Bump minor version in version.rb, print release commands |
| `rake bump:major`         | Bump major version in version.rb, print release commands |
```

2. Replace the "Continuous integration" paragraph that says automated
   publishing is "planned but not yet wired" with:

```markdown
`.github/workflows/release.yml` triggers on a `v*.*.*` tag: it verifies the tag
matches `Traject::SolrPool::VERSION`, re-runs the specs, publishes via
`rubygems/release-gem` (OIDC Trusted Publishing — no stored API key), then
checksums the published gem and creates a GitHub Release with the gem and
checksum files attached. `gem push` / `git push` / pushing a tag remain
user-only actions; `rake bump:*` only edits `version.rb` and prints the next
commands.
```

3. If there is a settings list in `CLAUDE.md`, add `solr_writer.ping_path` and
   `solr_writer.ping_timeout` to it. If not, skip.

- [ ] **Step 8: Verify docs accuracy and full CI**

Manually confirm setting names, defaults, and method signatures in the docs
match the code from Tasks 1–4 (`ping_path`, `ping_timeout` default 5,
`ready?`/`ping` signatures, `build:checksum`, `bump:*`).

Run: `bundle exec rake ci`
Expected: bundler-audit clean, RuboCop clean, all specs pass.

- [ ] **Step 9: Commit**

```bash
git add README.md docs/usage.md CLAUDE.md docs/skills/README.md docs/agents/README.md
git commit -m "Document health check, pool reuse, release flow, and cross-gem refs"
```

---

## Self-Review

**1. Spec coverage:**

- Part 1 (health-check API) → Task 1 (`Connection#head/ping/ready?`, `TRANSPORT_ERRORS`) + Task 2 (writer delegation, `ping_path` derivation, `ping_timeout`). ✅
- HEAD-safety rationale → captured in code comments (Task 1 Step 3) and docs (Task 5 Step 1/3). ✅
- `ready?` any-response=up / transport=down semantics → Task 1 tests (200/405/404/transport) + Task 2 tests + documented explicitly (Task 5 Step 1). ✅
- Part 2 (release automation): `release.yml` → Task 4 Step 4; `build:checksum` → Task 4 Step 1; `/checksums/` gitignore → Task 4 Step 2; `bump:*` → Task 3. ✅
- Part 3 (docs): README/usage examples → Task 5 Steps 1–4; registry pool reuse → Task 5 Step 1; settings table → Task 5 Step 2; cross-gem GitHub URLs + `bundle show` → Task 5 Steps 5–6; CLAUDE.md → Task 5 Step 7. ✅
- Execution constraint (Opus-only agents) → Global Constraints. ✅

**2. Placeholder scan:** No TBD/TODO. All code blocks are complete and runnable. Cross-gem doc replacements name the exact sections. The only intentional conditional is Task 5 Step 7.3 ("if there is a settings list … else skip") and Step 5's cutover-note check — both are explicit inspections, not vague instructions.

**3. Type consistency:** `head(path, timeout:)`, `ping(path, timeout:)`, `ready?(path, timeout:)` on `Connection` (Task 1) match the calls in the writer delegators `connection.ping(@ping_path, timeout: ...)` / `connection.ready?(@ping_path, timeout: ...)` (Task 2). `VersionBumper.next(current, level)` / `LEVELS` (Task 3) match the `Rakefile` usage in Task 3 Step 5. `build:checksum` gem path uses `Traject::SolrPool::VERSION` consistently (Tasks 3–4). Writer settings `solr_writer.ping_path` / `solr_writer.ping_timeout` consistent across Tasks 2 and 5. ✅
