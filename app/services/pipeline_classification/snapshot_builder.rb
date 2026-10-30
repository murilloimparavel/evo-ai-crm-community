module PipelineClassification
  # Reuses the mature public-message minimizer with a standalone domain adapter;
  # no FollowupCampaign, template or commercial anchor is constructed or persisted.
  class SnapshotBuilder < Followups::SnapshotBuilder
    MAX_MESSAGE_CHARACTERS = 2000
    def initialize(result:, catalog:, conversation:, now: Time.current)
      @record, @catalog, @conversation, @now = result, catalog, conversation, now
      @limits = { 'max_messages' => MAX_MESSAGES, 'max_message_characters' => MAX_MESSAGE_CHARACTERS, 'max_request_bytes' => MAX_BYTES }
    end

    private def serialize(message, index)
      super.merge('delivery' => message.incoming? ? 'customer_received' : 'business_accepted')
    end

    def public_messages
      base = super
      incoming = base.where(message_type: :incoming)
      outgoing = base.where(message_type: :outgoing, status: %w[sent delivered read]).where.not(source_id: [nil, ''])
      incoming.or(outgoing)
    end

    def call
      raise Unsafe, 'snapshot_identity_mismatch' unless @record.conversation_id == @conversation.id && @record.pipeline_id == @catalog.pipeline_id
      source = public_messages.find_by(id: @record.source_incoming_message_id)
      raise Unsafe, 'missing_source_incoming' unless source&.incoming?
      state = PipelineClassificationState.find_by(pipeline_id: @catalog.pipeline_id, conversation_id: @conversation.id)
      raise Unsafe, 'stale_source_incoming' unless state&.source_incoming_message_id == source.id && state.generation == @record.generation && state.revision == @record.revision
      # Select a complete contiguous tail of public messages, never partial
      # content. Event acceptance sequence resolves equal-clock incoming ties.
      quote = ActiveRecord::Base.connection.quote(@catalog.pipeline_id)
      query = public_messages.joins("LEFT JOIN (SELECT message_id, accepted_generation FROM pipeline_classification_events WHERE pipeline_id = #{quote}) accepted_events ON accepted_events.message_id = messages.id")
      newest = query.select('messages.*', 'accepted_events.accepted_generation AS accepted_generation')
        .reorder(Arel.sql('messages.created_at DESC, COALESCE(accepted_events.accepted_generation, 0) DESC')).limit(MAX_MESSAGES + 1).to_a
      history_truncated = newest.size > MAX_MESSAGES
      messages = newest.first(MAX_MESSAGES)
      # A tie at the cut boundary without acceptance history cannot be silently
      # reordered or guessed from random UUIDs.
      newest.group_by(&:created_at).each_value do |group|
        next if group.size < 2
        orders = group.map { |message| message['accepted_generation'].to_i }
        raise Unsafe, 'ambiguous_message_order' if orders.any?(&:zero?) || orders.uniq.size != orders.size
      end
      messages.reverse!
      raise Unsafe, 'missing_mandatory_message' unless messages.any? { |message| message.id == source.id }
      profile = @catalog.snapshot.fetch('classification')
      crm = Followups::SnapshotContext.new(profile.fetch('context_sources')).call(conversation: @conversation)
      selected_keys = profile.fetch('context_sources').fetch('fields', []).map { |field| field.fetch('key') }
      raise Unsafe, 'missing_selected_context' unless (selected_keys - crm.keys).empty?
      # Selected fields are assertions from the CRM, never authoritative financial
      # facts. The typed source allowlist offers no PMS or payment proof connector.
      state_data = { 'content_is_untrusted_data' => true, 'conversation_status' => @conversation.status,
        'crm_attributes_are_not_financial_proof' => true, 'crm' => crm, 'history_truncated' => history_truncated,
        'messages' => messages.map.with_index { |message, index| serialize(message, index) } }
      compiled = Catalog.from_revision(@catalog).compiled
      item = @conversation.pipeline_items.find_by(pipeline_id: @catalog.pipeline_id, completed_at: nil)
      state_data['current_stage'] = compiled.fetch('aliases').key(item&.pipeline_stage_id) || 'not_participating'
      raise Unsafe, 'snapshot_too_large' if JSON.generate(model: profile.fetch('model'), state: state_data, questions: compiled.fetch('questions')).bytesize > MAX_BYTES
      references = { pipeline_id: @catalog.pipeline_id, conversation_id: @conversation.id, inbox_id: @conversation.inbox_id,
        generation: @record.generation, revision: @record.revision, source_incoming_message_id: source.id,
        pipeline_item_id: item&.id, pipeline_stage_id: item&.pipeline_stage_id,
        catalog_hash: @catalog.catalog_hash, context_digest: Lifecycle.context_digest(@catalog.pipeline, @conversation),
        message_digests: messages.map { |message| [message.id, Digest::SHA256.hexdigest(message.content.to_s)] } }
      { state: state_data, references: references, snapshot_hash: Catalog.digest({ 'state' => state_data, 'references' => references.deep_stringify_keys }),
        valid_until: [@record.expires_at, @record.created_at + profile.fetch('snapshot_ttl_seconds').seconds].min }
    rescue Unsafe, Followups::SnapshotContext::Invalid, Followups::SnapshotContext::InvalidValue => error
      { state: nil, references: {}, valid_until: @now, reason: error.message }
    end
  end
end
