# frozen_string_literal: true

RSpec.describe Traject::SolrPool::Connection, :solr_stub do
  subject(:connection) { described_class.new(origin: 'http://solr.test:8983', pool_size: 2) }

  it 'exposes the origin it was built with' do
    expect(connection.origin).to eq('http://solr.test:8983')
  end

  it 'posts a body to a relative path resolved against the origin' do
    stub = stub_solr_update('http://solr.test:8983/solr/core/update')
    connection.post('/solr/core/update', body: '[]')
    expect(stub).to have_been_requested
  end

  it 'gets a relative path with query params resolved against the origin' do
    stub = stub_solr_get('http://solr.test:8983/solr/core/get?id=abc')
    connection.get('/solr/core/get', params: { id: 'abc' })
    expect(stub).to have_been_requested
  end

  it 'sends the configured auth as an Authorization header' do
    conn = described_class.new(origin: 'http://solr.test:8983', pool_size: 1, auth: 'Basic dXNlcjpwYXNz')
    stub = stub_solr_update('http://solr.test:8983/x').with(headers: { 'Authorization' => 'Basic dXNlcjpwYXNz' })
    conn.post('/x', body: '[]')
    expect(stub).to have_been_requested
  end

  it 'gives different credentials different pools' do
    a = described_class.new(origin: 'http://solr.test:8983', pool_size: 1, auth: 'Basic AAA')
    b = described_class.new(origin: 'http://solr.test:8983', pool_size: 1, auth: 'Basic BBB')
    expect(a.send(:pool)).not_to be(b.send(:pool))
  end

  it 'does not leak the auth credential in inspect' do
    conn = described_class.new(origin: 'http://solr.test:8983', pool_size: 1, auth: 'Basic dXNlcjpzM2NyZXQ=')
    expect(conn.inspect).to eq('#<Traject::SolrPool::Connection origin=http://solr.test:8983 ' \
                               'pool_size=1 options=[headers, auth]>')
  end

  it 'does not leak the auth credential in to_s' do
    conn = described_class.new(origin: 'http://solr.test:8983', pool_size: 1, auth: 'Basic dXNlcjpzM2NyZXQ=')
    expect(conn.to_s).to eq('#<Traject::SolrPool::Connection origin=http://solr.test:8983 ' \
                            'pool_size=1 options=[headers, auth]>')
  end
end
