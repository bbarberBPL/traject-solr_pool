# frozen_string_literal: true

require_relative '../../tasks/version_bumper'

RSpec.describe VersionBumper do
  describe '.next' do
    it 'bumps the patch segment' do
      expect(described_class.next('0.1.0', :patch)).to eq('0.1.1')
    end

    it 'bumps the minor segment and resets patch' do
      expect(described_class.next('0.1.5', :minor)).to eq('0.2.0')
    end

    it 'bumps the major segment and resets minor and patch' do
      expect(described_class.next('1.4.2', :major)).to eq('2.0.0')
    end

    it 'accepts a string level' do
      expect(described_class.next('0.1.0', 'patch')).to eq('0.1.1')
    end

    it 'raises on an unknown level' do
      expect { described_class.next('0.1.0', :nope) }.to raise_error(ArgumentError)
    end

    it 'raises on a malformed version' do
      expect { described_class.next('0.1', :patch) }.to raise_error(ArgumentError)
    end
  end
end
