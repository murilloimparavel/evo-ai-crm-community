require 'rails_helper'

RSpec.describe Internal::RemoveStaleRedisKeysJob do
  it 'enqueues the cleanup without an argument' do
    expect { described_class.perform_now }
      .to have_enqueued_job(Internal::ProcessStaleRedisKeysJob).with(no_args)
  end

  it 'accepts the legacy nil argument and runs the cleanup service' do
    service = instance_double(Internal::RemoveStaleRedisKeysService, perform: 0)
    allow(Internal::RemoveStaleRedisKeysService).to receive(:new).and_return(service)

    Internal::ProcessStaleRedisKeysJob.perform_now(nil)

    expect(service).to have_received(:perform)
  end
end
