# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'bundler/audit/task'

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
