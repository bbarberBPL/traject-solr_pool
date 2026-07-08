# frozen_string_literal: true

require 'json'
require 'uri'
require 'base64'
require 'http'
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

      class MaxSkippedRecordsExceeded < RuntimeError; end

      # Raised when Solr returns a non-2xx response; carries the raw response.
      # Its #response is an http.rb HTTP::Response (use #code / #to_s), not an
      # HTTPClient message.
      class BadHttpResponse < RuntimeError
        attr_reader :response

        def initialize(msg, response = nil)
          solr_error = find_solr_error(response)
          msg = "#{msg}: #{solr_error}" if solr_error
          super(msg)
          @response = response
        end

        private

        def find_solr_error(response)
          return nil unless response&.to_s && response.headers['Content-Type'].to_s.start_with?('application/json')

          JSON.parse(response.to_s).dig('error', 'msg')
        rescue JSON::ParserError
          nil
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

      def put(context)
        @thread_pool.raise_collected_exception!
        @batched_queue << context
        return if @batched_queue.size < @batch_size

        batch = Traject::Util.drain_queue(@batched_queue)
        @thread_pool.maybe_in_thread_pool(batch) { |b| send_batch(b) }
      end

      def flush
        send_batch(Traject::Util.drain_queue(@batched_queue))
      end

      def send_batch(batch)
        return if batch.empty?

        json_package = JSON.generate(batch.map(&:output_hash))
        begin
          resp = connection.post(request_path, body: json_package)
        rescue StandardError => e
          exception = e
        end

        return if exception.nil? && resp.status == 200

        log_batch_failure(exception, resp)
        batch.each { |c| send_single(c) }
      end

      def send_single(context)
        json_package = JSON.generate([context.output_hash])
        resp = connection.post(request_path, body: json_package)
        unless resp.status == 200
          raise BadHttpResponse.new("Unexpected HTTP response status #{resp.code} from POST", resp)
        end
      rescue *skippable_exceptions => e
        handle_skipped(context, e)
      end

      def skipped_record_count
        @skipped_record_incrementer.value
      end

      def close
        @thread_pool.raise_collected_exception!

        batch = Traject::Util.drain_queue(@batched_queue)
        @thread_pool.maybe_in_thread_pool { send_batch(batch) } unless batch.empty?

        shutdown_thread_pool if @thread_pool_size&.positive?

        @thread_pool.raise_collected_exception!
        commit if @commit_on_close
        # Pool is intentionally left warm in the registry for reuse by later
        # writers/readers on this origin; teardown is the host app's concern.
      end

      def commit(query_params = nil)
        query_params ||= @commit_solr_update_args || { 'commit' => 'true' }
        logger.info("#{self.class.name} sending commit to solr at url #{@solr_update_url}...")

        resp = connection.get(request_path_for(query_params))
        raise "Could not commit to Solr: #{resp.code} #{resp}" unless resp.status == 200
      end

      def delete(id)
        json_package = JSON.generate(delete: id)
        resp = connection.post(request_path, body: json_package)
        raise "Could not delete #{id.inspect}, http response #{resp.code}: #{resp}" unless resp.status == 200
      end

      def delete_all!
        delete(query: '*:*')
      end

      private

      def shutdown_thread_pool
        elapsed = @thread_pool.shutdown_and_wait
        logger.warn("Waited #{elapsed}s for all threads") if elapsed > 60
        return unless skipped_record_count.positive?

        logger.warn("#{self.class.name}: #{skipped_record_count} skipped records")
      end

      # Relative path (plus any query) so requests resolve against the pool
      # origin rather than re-encoding the absolute URL.
      def request_path
        uri = URI.parse(@solr_update_url)
        uri.query ? "#{uri.path}?#{uri.query}" : uri.path
      end

      def request_path_for(query_params)
        base = request_path
        return base unless query_params

        separator = base.include?('?') ? '&' : '?'
        "#{base}#{separator}#{URI.encode_www_form(query_params)}"
      end

      def log_batch_failure(exception, resp)
        message = if exception
                    Traject::Util.exception_to_log_message(exception)
                  else
                    "Solr response: #{resp.code}: #{resp}"
                  end
        logger.error('Error in Solr batch add. Will retry documents individually ' \
                     "at performance penalty: #{message}")
      end

      def handle_skipped(context, exception)
        logger.error("Could not add record #{context.record_inspect}: #{skip_message(exception)}")
        @skipped_record_incrementer.increment
        return unless @max_skipped && skipped_record_count > @max_skipped

        raise MaxSkippedRecordsExceeded,
              "#{self.class.name}: Exceeded maximum number of skipped records " \
              "(#{@max_skipped}): aborting: #{exception.message}"
      end

      def skip_message(exception)
        return Traject::Util.exception_to_log_message(exception) unless exception.is_a?(BadHttpResponse)

        "Solr error response: #{exception.response.code}: #{exception.response}"
      end

      def skippable_exceptions
        @skippable_exceptions ||= settings['solr_writer.skippable_exceptions'] || [
          HTTP::TimeoutError,
          HttpConnectionPool::TimeoutError,
          HTTP::ConnectionError,
          SocketError,
          Errno::ECONNREFUSED,
          BadHttpResponse
        ]
      end

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
