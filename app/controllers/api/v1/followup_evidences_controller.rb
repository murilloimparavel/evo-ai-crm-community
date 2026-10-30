class Api::V1::FollowupEvidencesController < Api::V1::BaseController
  require_permissions({ preview: 'pipeline_items.update', create: 'pipeline_items.update' })
  before_action :human_operator!
  before_action :load_target!

  def preview
    evidence = build_evidence
    reason = Followups::EvidenceApproval.invalid_reason(evidence)
    render json: { campaign_id: @campaign.id, conversation_id: @conversation.id, pipeline_item_id: @item.id,
                   source_incoming_message_id: @incoming.id, anchor_message_id: @anchor.id, anchor_digest: evidence.anchor_digest,
                   delivery_status: @anchor.status, eligible: reason.nil?, reason: reason }
  end

  def create
    digest = params.require(:anchor_digest)
    unless digest.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(digest, Followups::EvidenceApproval.digest(@anchor.reload))
      render json: { error: 'anchor_digest_changed' }, status: :conflict
      return
    end
    evidence = Followups::EvidenceApproval.new(campaign: @campaign, conversation: @conversation, pipeline_item: @item,
                                               incoming: @incoming, anchor: @anchor, actor: Current.user).call
    render json: { id: evidence.id, evidence_method: evidence.evidence_method, verified_at: evidence.verified_at,
                   conversation_id: evidence.conversation_id, pipeline_item_id: evidence.pipeline_item_id,
                   anchor_message_id: evidence.anchor_message_id }, status: :created
  rescue Followups::EvidenceApproval::InvalidEvidence => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def human_operator!
    return if Current.user.is_a?(User) && !service_authenticated?

    render json: { error: 'human_operator_required' }, status: :forbidden
  end

  # Preserve the exact evidence identity and digest checks before accepting an approval write.
  # rubocop:disable Metrics/AbcSize
  def load_target!
    @campaign = FollowupCampaign.find(params.require(:campaign_id))
    @item = PipelineItem.find(params.require(:pipeline_item_id))
    authorize @item.pipeline, :update_items?
    @conversation = Conversation.find(params.require(:conversation_id))
    unless @item.conversation_id == @conversation.id && @item.pipeline_stage_id == @campaign.pipeline_stage_id &&
           @item.pipeline_id == @item.pipeline_stage.pipeline_id && @campaign.inbox_id == @conversation.inbox_id
      raise ActiveRecord::RecordNotFound
    end

    @incoming = @conversation.messages.find(params.require(:source_incoming_message_id))
    @anchor = @conversation.messages.find(params.require(:anchor_message_id))
  end
  # rubocop:enable Metrics/AbcSize

  def build_evidence
    FollowupAnchorEvidence.new(followup_campaign: @campaign, conversation: @conversation, pipeline_item: @item,
                               source_incoming_message: @incoming, anchor_message: @anchor, verified_by: Current.user, verified_at: Time.current,
                               anchor_digest: Followups::EvidenceApproval.digest(@anchor))
  end
end
