# frozen_string_literal: true

RSpec.describe Traject::SolrPool::SolrJsonWriter, :solr_stub do
  def writer(settings = {})
    described_class.new({ 'solr.url' => 'http://solr.test:8983/solr/core' }.merge(settings))
  end

  def context(hash)
    Traject::Indexer::Context.new(output_hash: hash)
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

  describe 'credential safety' do
    it 'strips embedded credentials from the update url and origin' do
      w = described_class.new('solr.url' => 'http://user:secret@solr.test:8983/solr/core')
      expect([w.solr_update_url, w.connection.origin])
        .to eq(['http://solr.test:8983/solr/core/update/json', 'http://solr.test:8983'])
    end
  end

  describe 'put and batching' do
    it 'posts a full batch as a JSON array once batch_size is reached' do
      stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
      w = writer('solr_writer.batch_size' => 2, 'solr_writer.thread_pool' => 0)
      w.put(context('id' => '1'))
      w.put(context('id' => '2'))
      expect(stub.with { |req| JSON.parse(req.body).length == 2 }).to have_been_requested
    end

    it 'does not post before the batch is full' do
      stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
      w = writer('solr_writer.batch_size' => 5, 'solr_writer.thread_pool' => 0)
      w.put(context('id' => '1'))
      expect(stub).not_to have_been_requested
    end
  end

  describe 'error handling' do
    it 'retries a failed batch as individual records' do
      stub_request(:post, 'http://solr.test:8983/solr/core/update/json')
        .to_return({ status: 500, body: '{}' }, { status: 200, body: '{}' })
      w = writer('solr_writer.batch_size' => 1, 'solr_writer.thread_pool' => 0,
                 'solr_writer.max_skipped' => -1)
      expect { w.put(context('id' => '1')) }.not_to raise_error
    end

    it 'raises MaxSkippedRecordsExceeded past the skip limit' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json', status: 500, body: '{}')
      w = writer('solr_writer.batch_size' => 1, 'solr_writer.thread_pool' => 0,
                 'solr_writer.max_skipped' => 0)
      expect { w.put(context('id' => '1')) }
        .to raise_error(described_class::MaxSkippedRecordsExceeded)
    end

    it 'counts skipped records' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json', status: 500, body: '{}')
      w = writer('solr_writer.batch_size' => 1, 'solr_writer.thread_pool' => 0,
                 'solr_writer.max_skipped' => -1)
      w.put(context('id' => '1'))
      expect(w.skipped_record_count).to eq(1)
    end
  end

  describe 'close' do
    it 'flushes queued records on close' do
      stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
      w = writer('solr_writer.batch_size' => 100, 'solr_writer.thread_pool' => 0)
      w.put(context('id' => '1'))
      w.close
      expect(stub).to have_been_requested
    end

    it 'leaves the pool warm after close' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json')
      w = writer('solr_writer.thread_pool' => 0)
      w.put(context('id' => '1'))
      w.close
      expect(HttpConnectionPool::Registry.instance.stats.map { |s| s[:origin] }).to include(w.connection.origin)
    end

    it 'commits on close when configured' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json')
      commit = stub_solr_get('http://solr.test:8983/solr/core/update/json?commit=true')
      w = writer('solr_writer.thread_pool' => 0, 'solr_writer.commit_on_close' => 'true')
      w.close
      expect(commit).to have_been_requested
    end
  end

  describe 'delete' do
    it 'posts a delete-by-id document' do
      stub = stub_solr_update('http://solr.test:8983/solr/core/update/json')
             .with { |req| JSON.parse(req.body) == { 'delete' => 'abc' } }
      writer('solr_writer.thread_pool' => 0).delete('abc')
      expect(stub).to have_been_requested
    end

    it 'raises on a non-200 delete' do
      stub_solr_update('http://solr.test:8983/solr/core/update/json', status: 500)
      expect { writer('solr_writer.thread_pool' => 0).delete('abc') }.to raise_error(RuntimeError)
    end
  end
end
