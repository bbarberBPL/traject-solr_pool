# frozen_string_literal: true

require 'json'
require 'uri'
require 'concurrent/atomic/atomic_fixnum'
require 'traject/util'
require 'traject/thread_pool'

require_relative 'connection'

module Traject
  module SolrPool
    # Drop-in replacement for Traject::SolrJsonWriter that sends every Solr HTTP
    # call through a persistent http_connection_pool pool. Reuses the stock
    # writer's settings vocabulary and public surface; all HTTP is delegated to
    # Traject::SolrPool::Connection.
    class SolrJsonWriter
      URI_REGEXP = URI::DEFAULT_PARSER.make_regexp.freeze
      DEFAULT_MAX_SKIPPED = 0
      DEFAULT_BATCH_SIZE  = 100

      # Raised when Solr returns a non-2xx response; carries the raw response.
      class BadHttpResponse < RuntimeError
        attr_reader :response

        def initialize(msg, response)
          super(msg)
          @response = response
        end
      end

      attr_reader :settings, :thread_pool_size, :batched_queue, :solr_update_url,
                  :connection, :pool_size

      def initialize(arg_settings)
        @settings = Traject::Indexer::Settings.new(arg_settings)
        configure_from_settings
      end

      def solr_update_url_with_query(query_params)
        return @solr_update_url unless query_params

        "#{@solr_update_url}?#{URI.encode_www_form(query_params)}"
      end

      def logger
        settings['logger'] ||= Yell.new($stderr, level: 'gt.fatal')
      end

      private

      def configure_from_settings
        configure_skipped
        configure_batching
        configure_pools
        configure_commit
      end

      def configure_skipped
        @max_skipped = (@settings['solr_writer.max_skipped'] || DEFAULT_MAX_SKIPPED).to_i
        @max_skipped = nil if @max_skipped.negative?
        @skipped_record_incrementer = Concurrent::AtomicFixnum.new(0)
      end

      def configure_batching
        @batch_size = (@settings['solr_writer.batch_size'] || DEFAULT_BATCH_SIZE).to_i
        @batch_size = 1 if @batch_size < 1
        @batched_queue = Queue.new
      end

      def configure_pools
        @solr_update_url, user, password = determine_solr_update_url
        @thread_pool_size = (@settings['solr_writer.thread_pool'] || 1).to_i
        @pool_size = (@settings['solr_pool.pool_size'] || (@thread_pool_size + 1)).to_i
        @connection = build_connection(user, password)
        @thread_pool = Traject::ThreadPool.new(@thread_pool_size)
        logger.info("   #{self.class.name} writing to '#{@solr_update_url}' " \
                    "#{'(with HTTP basic auth) ' if user || password}" \
                    "in batches of #{@batch_size} with #{@thread_pool_size} bg threads")
      end

      def configure_commit
        @commit_on_close = (@settings['solr_writer.commit_on_close'] ||
                            @settings['solrj_writer.commit_on_close']).to_s == 'true'
        @solr_update_args = @settings['solr_writer.solr_update_args']
        @commit_solr_update_args = @settings['solr_writer.commit_solr_update_args']
      end

      # Splits origin (scheme://host:port) from request path; auth goes to
      # Connection as an Authorization header, never baked into the origin.
      def build_connection(user, password)
        uri = URI.parse(@solr_update_url)
        origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        Connection.new(
          origin: origin,
          pool_size: @pool_size,
          pool_timeout: @settings['solr_writer.pool_timeout'],
          auth: basic_auth_header(user, password),
          timeout: @settings['solr_writer.http_timeout']
        )
      end

      def basic_auth_header(user, password)
        return nil unless user || password

        require 'base64'
        "Basic #{Base64.strict_encode64("#{user}:#{password}")}"
      end

      def determine_solr_update_url
        url = resolve_solr_url
        parsed = URI.parse(url)
        user = parsed.user
        password = parsed.password
        parsed.user = nil
        parsed.password = nil
        [parsed.to_s,
         @settings['solr_writer.basic_auth_user'] || user,
         @settings['solr_writer.basic_auth_password'] || password]
      end

      def resolve_solr_url
        if settings['solr.update_url']
          validate_url!(settings['solr.update_url'], 'solr.update_url')
        else
          derive_solr_update_url_from_solr_url(settings['solr.url'])
        end
      end

      def validate_url!(url, setting_name)
        unless /^#{URI_REGEXP}$/o.match?(url)
          raise ArgumentError,
                "#{self.class.name} setting `#{setting_name}` doesn't look like a URL: `#{url}`"
        end

        url
      end

      def derive_solr_update_url_from_solr_url(url)
        if url.nil?
          raise ArgumentError,
                "#{self.class.name}: Neither solr.update_url nor solr.url set; need at least one"
        end

        validate_url!(url, 'solr.url')
        [url.chomp('/'), 'update', 'json'].join('/')
      end
    end
  end
end
