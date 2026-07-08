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
