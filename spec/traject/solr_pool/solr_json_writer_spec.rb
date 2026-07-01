# frozen_string_literal: true

RSpec.describe Traject::SolrPool::SolrJsonWriter, :solr_stub do
  def writer(settings = {})
    described_class.new({ 'solr.url' => 'http://solr.test:8983/solr/core' }.merge(settings))
  end

  describe 'update url derivation' do
    it 'derives the update handler from solr.url' do
      expect(writer.solr_update_url).to eq('http://solr.test:8983/solr/core/update/json')
    end

    it 'uses solr.update_url verbatim when provided' do
      w = described_class.new('solr.update_url' => 'http://solr.test:8983/solr/core/update')
      expect(w.solr_update_url).to eq('http://solr.test:8983/solr/core/update')
    end

    it 'raises when neither solr.url nor solr.update_url is set' do
      expect { described_class.new({}) }.to raise_error(ArgumentError)
    end
  end

  describe 'connection binding' do
    it 'builds a Connection bound to the solr origin' do
      expect(writer.connection.origin).to eq('http://solr.test:8983')
    end
  end

  describe 'pool size' do
    it 'defaults pool_size to the writer thread pool plus caller headroom' do
      expect(writer('solr_writer.thread_pool' => 3).pool_size).to eq(4)
    end

    it 'honours an explicit solr_pool.pool_size' do
      expect(writer('solr_pool.pool_size' => 9).pool_size).to eq(9)
    end
  end

  describe 'query params' do
    it 'appends solr_update_args as a query string' do
      w = writer('solr_writer.solr_update_args' => { commitWithin: 1000 })
      expect(w.solr_update_url_with_query(w.instance_variable_get(:@solr_update_args)))
        .to eq('http://solr.test:8983/solr/core/update/json?commitWithin=1000')
    end
  end
end
