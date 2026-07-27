# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in traject-solr_pool.gemspec
gemspec

# Edge-traject override, no longer needed: released traject 3.9.0 relaxes its
# HTTP cap to `http >= 3.0, < 7`, so it co-installs with http_connection_pool's
# `http ~> 6.0` straight from RubyGems. Kept commented as a hook in case a local
# traject checkout is needed again (e.g. to test an unreleased fix).
# gem 'traject', path: '../traject-edge'

group :development, :test do
  gem 'bundler-audit', '~> 0.9', require: false
  gem 'irb', '~> 1.14'
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rake', require: false
  gem 'rubocop-rspec', require: false
end

group :test do
  gem 'activejob', '~> 7.2'
  gem 'activesupport', '~> 7.2'
  gem 'sidekiq', '>= 8', '< 9'
  gem 'webmock', '~> 3.23'
  gem 'zeitwerk', '~> 2.6'
end
