# frozen_string_literal: true

require 'traject'
require 'http_connection_pool'

require_relative 'solr_pool/version'
require_relative 'solr_pool/connection'

module Traject
  module SolrPool
    class Error < StandardError; end
    # Your code goes here...
  end
end
