module Followups
  class DebouncedClassifier
    def initialize(conversation:, generation:, evaluator_factory: nil, now: Time.current)
      @conversation, @generation, @factory, @now = conversation, generation, evaluator_factory, now
    end

    def call
      rows = []
      @conversation.with_lock do
        state = FollowupConversationState.for!(@conversation)
        state.lock!
        next [] unless state.classification_generation == @generation && state.classification_due_at && state.classification_due_at <= @now
        unless @conversation.messages.incoming.exists?(id: state.latest_incoming_message_id)
          state.update!(classification_due_at: nil, latest_incoming_message_id: nil, classification_generation: state.classification_generation + 1)
          next []
        end

        DebounceCoordinator.campaigns_for(@conversation, now: @now).each do |campaign|
          next if campaign.pipeline_catalog? # The pipeline owns its own debounce and paid evaluation.
          next unless campaign.policy_object.valid? && campaign.policy['reclassification_enabled'] == true
          next if Eligibility.new(campaign: campaign, conversation: @conversation, now: @now).reason

          config = campaign.policy['classifier']
          rows << FollowupClassification.create_or_find_by!(followup_campaign: campaign, conversation: @conversation, generation: @generation, policy_version: campaign.policy_version, model: config['model'], question_version: config['question_version']) do |row|
            row.assign_attributes(source_incoming_message_id: state.latest_incoming_message_id, revision: state.revision, expires_at: @now + campaign.policy['authorization_ttl_seconds'].seconds)
          end
        end
        state.update!(classification_due_at: nil)
      end
      rows.each do |row|
        evaluator = @factory ? @factory.call(row) : Evaluator.new(subject: row)
        evaluator.call
      end
      rows
    end
  end
end
