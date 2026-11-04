RSpec.describe 'pipeline classification queue isolation', type: :job do
  it 'routes every classification job to its dedicated queue' do
    jobs = [PipelineClassification::SchedulerJob, PipelineClassification::EvaluateJob,
            PipelineClassification::ApplyDecisionJob, PipelineClassification::RetentionJob]

    expect(jobs.map(&:queue_name)).to all(eq('pipeline_classification'))
  end

  it 'subscribes the CRM Sidekiq worker and scheduler to the dedicated queue' do
    worker_config = YAML.safe_load(ERB.new(Rails.root.join('config/sidekiq.yml').read).result,
                                   permitted_classes: [Symbol], aliases: true)
    schedule = YAML.safe_load(Rails.root.join('config/schedule.yml').read)

    expect(worker_config.fetch(':queues')).to include('pipeline_classification')
    expect(schedule.dig('pipeline_classification_scheduler_job', 'queue')).to eq('pipeline_classification')
    expect(schedule.dig('pipeline_classification_retention_job', 'queue')).to eq('pipeline_classification')
  end
end
