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
