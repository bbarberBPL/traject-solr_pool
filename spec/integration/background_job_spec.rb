# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Background job integration', :background_jobs, :integration, :solr_stub do
  before do
    stub_request(:post, 'http://solr.jobs.test:8983/solr/core/update/json')
      .to_return(status: 200, body: '{}')
  end

  it 'runs the pooled writer inside a Sidekiq job' do
    JobHelpers::IndexJob.perform_async('doc-1')
    expect(
      a_request(:post, 'http://solr.jobs.test:8983/solr/core/update/json')
    ).to have_been_made
  end

  it 'shares one pool across many sequential jobs against the same origin' do
    25.times { |i| JobHelpers::IndexJob.perform_async("doc-#{i}") }
    origins = registry.stats.map { |s| s[:origin] }
    expect(origins.count { |o| o == 'http://solr.jobs.test:8983' }).to eq(1)
  end
end
