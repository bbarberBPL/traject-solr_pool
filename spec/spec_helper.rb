# frozen_string_literal: true

require 'traject/solr_pool'
require 'webmock/rspec'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include WebmockHelpers, :solr_stub
  config.include ThreadSafetyHelpers, :thread_safety

  # Every example starts with a clean global pool registry so pools never leak
  # between examples (locally-built pools must be closed by their own example).
  config.after do
    HttpConnectionPool::Registry.instance.close_all
  end
end
