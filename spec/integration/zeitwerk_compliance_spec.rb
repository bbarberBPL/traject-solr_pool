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
