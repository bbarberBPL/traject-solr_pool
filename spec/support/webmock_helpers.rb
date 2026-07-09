# frozen_string_literal: true

require 'webmock/rspec'

# HTTP stubbing helpers for Solr update/get endpoints. Included into any
# example group tagged :solr_stub (wired in spec_helper.rb). WebMock intercepts
# real http.rb requests, so specs exercise the actual pool without a live Solr.
module WebmockHelpers
  SOLR_OK = { 'responseHeader' => { 'status' => 0, 'QTime' => 1 } }.freeze

  def stub_solr_update(url, status: 200, body: SOLR_OK.to_json)
    stub_request(:post, url).to_return(
      status: status,
      body: body,
      headers: { 'Content-Type' => 'application/json' }
    )
  end

  def stub_solr_get(url, status: 200, body: '{}')
    stub_request(:get, url).to_return(
      status: status,
      body: body,
      headers: { 'Content-Type' => 'application/json' }
    )
  end
end
