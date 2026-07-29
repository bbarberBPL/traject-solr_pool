# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'bundler/audit/task'
require_relative 'tasks/version_bumper'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new
Bundler::Audit::Task.new

# The default task runs offline, so `ci` only *checks* against whatever
# advisory DB is present. `audit` refreshes the DB from the network first;
# `bundle:audit:check` no-ops gracefully if the DB was never cloned.
desc 'Refresh the advisory DB, then scan dependencies for known CVEs'
task audit: ['bundle:audit:update', 'bundle:audit:check']

desc 'Audit dependencies (offline), run RuboCop, then the RSpec suite'
task ci: %i[bundle:audit:check rubocop spec]

task default: :ci

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
  print_release_steps(bumped)
end

def print_release_steps(bumped)
  puts <<~NEXT
    Next steps (run these yourself):
      git add #{VERSION_FILE}
      git commit -m 'Release v#{bumped}'
      git tag v#{bumped}
      git push && git push --tags
  NEXT
end

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
