# frozen_string_literal: true

require_relative 'lib/traject/solr_pool/version'

Gem::Specification.new do |spec|
  spec.name = 'traject-solr_pool'
  spec.version = Traject::SolrPool::VERSION
  spec.authors = ['bbarberBPL']
  spec.email = ['bbarber@bpl.org']

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

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .rubocop.yml])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'http_connection_pool', '~> 0.1'
  # NOTE: temporary floor. The last RELEASED traject caps http < 6, colliding
  # with http_connection_pool's http ~> 6.0. We depend on edge traject via a
  # Gemfile `path:` override until a release lifts that cap; then pin the real
  # released version here and remove the Gemfile override.
  spec.add_dependency 'traject', '>= 3.8.4', '~> 3.8'
end
