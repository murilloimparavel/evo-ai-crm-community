require 'digest'

module Followups
  class EvidenceApproval
    class InvalidEvidence < StandardError; end

    def self.digest(message)
      Digest::SHA256.hexdigest(JSON.generate([message.content.to_s, message.content_type, message.attachments.order(:id).pluck(:id)]))
    end

    # The approval contract binds all identity, delivery and evidence fields before accepting a human review.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def self.invalid_reason(evidence, now: Time.current)
      unless evidence&.conversation_id && evidence.pipeline_item_id && evidence.source_incoming_message_id &&
             evidence.anchor_message_id && evidence.verified_by_id
        return 'evidence_missing'
      end

      campaign = evidence.followup_campaign.reload
      incoming = evidence.source_incoming_message.reload
      anchor = evidence.anchor_message.reload
      conversation = evidence.conversation.reload
      item = evidence.pipeline_item.reload
      unless anchor.conversation_id == conversation.id && incoming.conversation_id == conversation.id &&
             anchor.inbox_id == campaign.inbox_id && incoming.inbox_id == campaign.inbox_id &&
             item.conversation_id == conversation.id && item.pipeline_stage_id == campaign.pipeline_stage_id
        return 'evidence_wrong_target'
      end
      unless anchor.outgoing? && !anchor.private? && (anchor.delivered? || anchor.read?) && anchor.source_id.present?
        return 'evidence_not_public_delivery'
      end
      return 'evidence_invalid_incoming' unless incoming.incoming? && !incoming.private?
      unless campaign.active_from && incoming.created_at >= campaign.active_from && anchor.created_at >= campaign.active_from
        return 'evidence_before_activation'
      end
      return 'evidence_wrong_order' if anchor.created_at < incoming.created_at
      return 'evidence_digest_changed' unless evidence.anchor_digest == digest(anchor)
      return 'evidence_incoming_changed' unless Eligibility.latest_incoming(conversation)&.id == incoming.id

      outbound = conversation.messages.outgoing.where(private: false).where.not(id: anchor.id).where('created_at >= ?', anchor.created_at)
      return 'evidence_outbound_changed' if outbound.exists?(followup_execution_id: nil)
      return 'evidence_future' if evidence.verified_at > now

      nil
    rescue ActiveRecord::RecordNotFound
      'evidence_missing'
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    # The approval contract binds all identity, delivery and evidence fields before accepting a human review.
    # rubocop:disable Metrics/ParameterLists
    def initialize(campaign:, conversation:, pipeline_item:, incoming:, anchor:, actor:, now: Time.current)
      @campaign = campaign
      @conversation = conversation
      @item = pipeline_item
      @incoming = incoming
      @anchor = anchor
      @actor = actor
      @now = now
    end
    # rubocop:enable Metrics/ParameterLists

    def call
      raise InvalidEvidence, 'human_actor_required' unless @actor.is_a?(User) && @actor.persisted?

      evidence = nil
      @conversation.with_lock do
        evidence = FollowupAnchorEvidence.find_or_initialize_by(followup_campaign: @campaign, conversation: @conversation,
                                                                source_incoming_message: @incoming, anchor_message: @anchor)
        evidence.assign_attributes(pipeline_item: @item, verified_by: @actor, verified_at: @now, anchor_digest: self.class.digest(@anchor.reload),
                                   evidence_method: 'operator_verified', metadata: {})
        reason = self.class.invalid_reason(evidence, now: @now)
        raise InvalidEvidence, reason if reason

        evidence.save!
      end
      Planner.new(evidence: evidence, now: @now).call
      evidence
    end
  end
end
