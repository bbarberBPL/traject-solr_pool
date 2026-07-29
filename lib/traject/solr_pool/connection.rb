# frozen_string_literal: true

require 'http_connection_pool'

module Traject
  module SolrPool
    # Reusable persistent-connection seam over http_connection_pool. Owns origin
    # binding and pool_options construction; exposes post/get that borrow a
    # pooled HTTP::Session. A future reader can reuse this unchanged.
    class Connection
      # Keyword bundle so initialize stays under the 5-param limit.
      Options = Struct.new(:headers, :auth, :timeout, keyword_init: true) do
        def to_pool_opts
          opts = { headers: headers }
          opts[:auth]    = auth    if auth
          opts[:timeout] = timeout if timeout
          opts
        end
      end

      # Transport-level failures that mean the server is unreachable. A returned
      # HTTP response of ANY status (2xx/4xx/5xx) is NOT in this set — it proves
      # the server answered. Kept independent of the writer's skippable list.
      TRANSPORT_ERRORS = [
        HTTP::TimeoutError,
        HttpConnectionPool::TimeoutError,
        HTTP::ConnectionError,
        SocketError,
        Errno::ECONNREFUSED
      ].freeze

      attr_reader :origin

      def initialize(origin:, pool_size:, pool_timeout: nil, **opts)
        @origin       = origin
        @pool_size    = pool_size
        @pool_timeout = pool_timeout
        @pool_options = Options.new(headers: opts.fetch(:headers, {}),
                                    auth: opts[:auth],
                                    timeout: opts[:timeout]).to_pool_opts
        @adapter      = build_adapter
      end

      def post(path, body:)
        @adapter.with_connection { |conn| conn.post(path, body: body) }
      end

      def get(path, params: {}, timeout: nil)
        @adapter.with_connection do |conn|
          client = timeout ? conn.timeout(timeout) : conn
          if params.empty?
            client.get(path)
          else
            client.get(path, params: params)
          end
        end
      end

      def head(path, timeout: nil)
        @adapter.with_connection do |conn|
          client = timeout ? conn.timeout(timeout) : conn
          client.head(path)
        end
      end

      # Raw health probe: returns the HTTP::Response (any status) so callers can
      # inspect it. Raises on transport failure. HEAD has no body to drain, so
      # it leaves the pooled persistent socket clean for reuse.
      def ping(path, timeout: nil)
        head(path, timeout: timeout)
      end

      # Liveness predicate. Any HTTP response means reachable -> true. Only a
      # transport failure means down -> false. Never raises.
      def ready?(path, timeout: nil)
        !ping(path, timeout: timeout).nil?
      rescue *TRANSPORT_ERRORS
        false
      end

      def release
        @adapter.release_connection_pool
      end

      # Metadata only: never print header values or the auth credential.
      def inspect
        "#<#{self.class} origin=#{@origin} pool_size=#{@pool_size} " \
          "options=[#{@pool_options.keys.join(', ')}]>"
      end
      alias to_s inspect

      private

      def build_adapter
        adapter = Object.new
        adapter.extend(HttpConnectionPool::Connectable)
        configure_adapter(adapter)
        adapter
      end

      def configure_adapter(adapter)
        adapter.base_url     = @origin
        adapter.pool_size    = @pool_size
        adapter.pool_timeout = @pool_timeout if @pool_timeout
        adapter.pool_options = @pool_options
      end

      def pool
        @adapter.connection_pool
      end
    end
  end
end
