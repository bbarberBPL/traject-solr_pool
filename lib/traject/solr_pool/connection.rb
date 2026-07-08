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

      attr_reader :origin

      def initialize(origin:, pool_size:, pool_timeout: nil, **opts)
        @origin       = origin
        @pool_size    = pool_size
        @pool_timeout = pool_timeout
        @pool_options = Options.new(headers: opts.fetch(:headers, {}),
                                    auth: opts[:auth],
                                    timeout: opts[:timeout]).to_pool_opts
        @adapter      = build_adapter
        pool # register the pool with the registry now so it is warm for reuse
      end

      def post(path, body:)
        @adapter.with_connection { |conn| conn.post(path, body: body) }
      end

      def get(path, params: {})
        if params.empty?
          @adapter.with_connection { |conn| conn.get(path) }
        else
          @adapter.with_connection { |conn| conn.get(path, params: params) }
        end
      end

      def release
        @adapter.release_connection_pool
      end

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
