require 'digest'

module Followups
  class Eligibility
    def self.latest_incoming(conversation)
      messages = conversation.messages.incoming
      state = FollowupConversationState.find_by(conversation_id: conversation.id)
      persisted_latest = messages.find_by(id: state&.latest_incoming_message_id) if state&.latest_incoming_message_id
      if persisted_latest && !messages.where('created_at > ?', persisted_latest.created_at).exists?
        return persisted_latest
      end

      messages.reorder(created_at: :desc, id: :desc).first
    end

    def self.legacy_overlap?(campaign)
      stage_rules = campaign.pipeline_stage&.automation_rules.to_h['rules']
      return true if Array(stage_rules).any? { |rule| rule.is_a?(Hash) && rule['trigger'] == 'inactivity' }

      Array(campaign.inbox&.agent_bot&.bot_config.to_h['inactivity_actions']).any?
    end

    def initialize(campaign:, conversation:, execution: nil, now: Time.current, dispatch: false)
      @campaign, @conversation, @execution, @now, @dispatch = campaign, conversation, execution, now, dispatch
    end

    def reason
      @campaign.reload
      @conversation.reload
      return 'campaign_off' unless @campaign.running?(@now)
      policy = @campaign.policy_object
      return 'invalid_policy' unless policy.valid?
      return 'wrong_inbox' unless @conversation.inbox_id == @campaign.inbox_id
      return 'closed_conversation' unless policy['allowed_statuses'].include?(@conversation.status)
      return 'human_assignee' if @conversation.assignee_id.present?
      return 'human_team' if @conversation.team_id.present?
      contact = @conversation.contact
      return 'missing_contact' unless contact
      return 'contact_blocked' if contact.reload.blocked?
      bot_binding = @conversation.inbox.agent_bot_inbox
      if bot_binding
        bot_binding.reload
        return 'inbox_bot_inactive' unless bot_binding.active?
        return 'inbox_bot_ignored_label' if bot_binding.has_ignored_labels?(@conversation)
        return 'inbox_bot_policy_block' if bot_binding.processing_block_reason(@conversation)
      end
      return 'legacy_overlap' if self.class.legacy_overlap?(@campaign)
      return 'overlapping_campaign' if FollowupCampaign.running.where(inbox_id: @campaign.inbox_id, pipeline_stage_id: @campaign.pipeline_stage_id).where.not(id: @campaign.id).exists?
      items = @conversation.pipeline_items.where(pipeline_stage_id: @campaign.pipeline_stage_id, completed_at: nil)
      return 'wrong_stage' unless items.count == 1
      item = items.first
      return 'pipeline_archived' unless item.pipeline_stage.pipeline.is_active?
      return 'pipeline_mismatch' unless item.pipeline_id == item.pipeline_stage.pipeline_id
      return 'wrong_item' if @execution && @execution.pipeline_item_id != item.id

      configured_ids = %w[blocking_label_ids opt_out_label_ids consent_label_ids].flat_map { |key| policy[key] }.uniq
      labels = Label.where(id: configured_ids).pluck(:id, :title).to_h
      return 'missing_label_configuration' unless labels.length == configured_ids.length
      return 'label_configuration_changed' unless labels == policy['label_bindings']
      names = [@conversation, contact].flat_map { |record| record.labels.reload.pluck(:name) }.uniq
      blocked_ids = policy['blocking_label_ids'] + policy['opt_out_label_ids']
      return 'blocking_label' if blocked_ids.any? { |id| names.include?(labels[id]) || names.include?(id) }
      return 'consent_missing' unless policy['consent_label_ids'].all? { |id| names.include?(labels[id]) || names.include?(id) }
      incoming = self.class.latest_incoming(@conversation)
      return 'missing_incoming' unless incoming && incoming.created_at >= @campaign.active_from
      return 'incoming_changed' if @execution && incoming.id != @execution.source_incoming_message_id
      human = @conversation.messages.outgoing.where(private: false, sender_type: 'User').where('created_at >= ?', incoming.created_at).exists?
      echo = @conversation.messages.outgoing.where(private: false).where('created_at >= ?', incoming.created_at).where("content_attributes ->> 'whatsapp_echo_message' = 'true'").exists?
      return 'human_intervention' if human || echo
      if @campaign.pipeline_catalog?
        classified = PipelineClassification::CurrentResult.call(pipeline: item.pipeline_stage.pipeline, conversation: @conversation, now: @now)
        return 'pipeline_classification_unavailable' unless classified
        return 'pipeline_classification_different_stage' unless classified.recommended_stage_id == @campaign.pipeline_stage_id
        if @execution && (@execution.pipeline_classification_result_id.present? || @execution.classification_catalog_hash.present?)
          return 'pipeline_classification_changed' unless @execution.pipeline_classification_result_id == classified.id && @execution.classification_catalog_hash == classified.catalog_hash
        end
      end
      return nil unless @execution

      return 'policy_changed' unless @execution.policy_version == @campaign.policy_version
      return 'execution_expired' unless @execution.expires_at > @now
      evidence_reason = EvidenceApproval.invalid_reason(@execution.followup_anchor_evidence, now: @now)
      return evidence_reason if evidence_reason
      state = FollowupConversationState.for!(@conversation)
      return 'revision_changed' if @execution.authorized_revision && state.revision != @execution.authorized_revision
      return 'cooldown' if state.cooldown_until && state.cooldown_until > @now && state.active_execution_id != @execution.id
      return 'outside_contact_window' unless policy.within_window?(@now)
      return nil unless @dispatch

      channel = @conversation.inbox.channel
      authorization = policy['channel_authorization']
      actual_provider = channel.respond_to?(:provider) ? channel.provider : channel.class.name
      return 'channel_not_authorized' unless authorization['approved'] == true && authorization['provider'] == actual_provider
      outside_window = incoming.created_at + authorization['window_seconds'].seconds <= @now
      return 'channel_window_closed' if outside_window && !authorization['template_required']
      if authorization['template_required']
        template = MessageTemplate.find_by(name: authorization['template_name'], channel_id: channel.id, channel_type: channel.class.name)
        return 'provider_template_unapproved' unless template&.active? && template.respond_to?(:approval_status) && template.approval_status == 'approved'
      end
      nil
    rescue ActiveRecord::RecordNotFound, TZInfo::InvalidTimezoneIdentifier
      'missing_target'
    end

    def self.in_cohort?(campaign, contact_id)
      cohort = campaign.policy['cohort'] || {}
      Digest::SHA256.hexdigest("#{cohort['salt']}:#{contact_id}").first(16).to_i(16) % 100 < cohort['percentage'].to_i
    end
  end
end
