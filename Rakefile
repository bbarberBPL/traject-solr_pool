# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'
require 'bundler/audit/task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new
Bundler::Audit::Task.new

task ci: %i[bundle:audit:check rubocop spec]
task default: :ci
