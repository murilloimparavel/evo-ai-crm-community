require 'rails_helper'

RSpec.describe Whatsapp::EvolutionApiUrl do
  describe '.normalize' do
    it 'removes trailing slashes and the Evolution manager suffix' do
      expect(described_class.normalize('https://evo.caldasindica.com/manager/'))
        .to eq('https://evo.caldasindica.com')
    end

    it 'adds https when the scheme is omitted' do
      expect(described_class.normalize('evo.caldasindica.com/'))
        .to eq('https://evo.caldasindica.com')
    end

    it 'preserves other path prefixes used by reverse proxies' do
      expect(described_class.normalize('https://evo.example.com/evolution/'))
        .to eq('https://evo.example.com/evolution')
    end

    it 'rejects credentials and query parameters' do
      expect { described_class.normalize('https://user:secret@evo.example.com?token=x') }
        .to raise_error(Whatsapp::EvolutionApiUrl::InvalidUrl)
    end
  end
end
