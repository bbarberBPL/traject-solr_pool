# frozen_string_literal: true

require 'sidekiq'
require 'sidekiq/testing'

# Helpers and job classes for the background-job integration spec. Included into
# any example group tagged :background_jobs. Sidekiq runs inline (enqueue =
# synchronous execution) so we exercise the worker path without Redis.
module JobHelpers
  def self.included(base)
    base.before { Sidekiq::Testing.inline! }
    base.after  { Sidekiq::Testing.fake! }
  end

  SOLR_URL = 'http://solr.jobs.test:8983/solr/core'

  class IndexJob
    include Sidekiq::Job

    def perform(id)
      writer = Traject::SolrPool::SolrJsonWriter.new(
        'solr.url' => SOLR_URL,
        'solr_writer.thread_pool' => 0,
        'solr_writer.batch_size' => 1
      )
      writer.put(Traject::Indexer::Context.new(output_hash: { 'id' => id }))
      writer.close
    end
  end

  def registry
    HttpConnectionPool::Registry.instance
  end
end
