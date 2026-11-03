require 'rails_helper'

RSpec.describe 'Concurrent default knowledge base creation' do
  self.use_transactional_tests = false

  it 'creates one default when two first article requests race' do # rubocop:disable RSpec/ExampleLength
    scope = "race-#{SecureRandom.hex(8)}"
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          controller = Api::V1::KnowledgeEntriesController.new
          allow(controller).to receive(:current_scope).and_return(scope)
          ready << true
          start.pop
          results << controller.send(:default_base).id
        rescue StandardError => e
          results << e
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)
    ids = Array.new(2) { results.pop }
    expect(ids).to all(be_a(String))
    expect(ids.uniq.size).to eq(1)
    expect(KnowledgeBase.where(account_scope: scope, legacy_default: true).count).to eq(1)
  ensure
    KnowledgeBase.where(account_scope: scope).delete_all if scope
  end
end
