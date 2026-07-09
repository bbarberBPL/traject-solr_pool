# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Writer concurrency', :integration, :solr_stub, :thread_safety do
  let(:received) { Concurrent::AtomicFixnum.new(0) }
  let(:solr_url) { 'http://solr.test:8983/solr/core' }
  let(:writer) do
    Traject::SolrPool::SolrJsonWriter.new(
      'solr.url' => solr_url,
      'solr_writer.batch_size' => 10,
      'solr_writer.thread_pool' => 4,
      'solr_pool.pool_size' => 4
    )
  end

  before do
    stub_request(:post, "#{solr_url}/update/json").to_return do |req|
      received.increment(JSON.parse(req.body).length)
      { status: 200, body: '{}' }
    end
  end

  it 'delivers every record with a multi-thread writer pool' do
    200.times { |i| writer.put(Traject::Indexer::Context.new(output_hash: { 'id' => i.to_s })) }
    writer.close
    expect(received.value).to eq(200)
  end
end
