# frozen_string_literal: true

module KnowledgeRuntime
  class Actions
    class Denied < StandardError; end

    def self.call(token:, proof_token:, body:)
      preliminary = CustomerHistory.verified_claims(token)
      ActionProof.verify!(token: proof_token, grant: preliminary, body: body)
      payload = JSON.parse(body)
      raise Denied unless payload.is_a?(Hash)

      ApplicationRecord.transaction do
        require_mutex_triggers!
        mutex!(preliminary.fetch('inbox_id'))
        authorized_action!(token, proof_token, body, preliminary, payload)
      end
    rescue JSON::ParserError, KeyError, CustomerHistory::Denied, ActionProof::Denied, ActiveRecord::RecordNotFound
      raise Denied
    end

    def self.authorized_action!(token, proof_token, body, preliminary, payload)
      conversation = Conversation.lock.find(preliminary.fetch('conversation_id'))
      # Validate AFTER the mutex: association revocations cannot interleave.
      grant = CustomerHistory.verified_claims(token)
      proof = ActionProof.verify!(token: proof_token, grant: grant, body: body)
      raise Denied unless conversation.inbox_id.to_s == grant['inbox_id'] && conversation.contact_id.to_s == grant['contact_id']

      execute_once!(conversation, grant, proof, payload)
    end

    def self.execute_once!(conversation, grant, proof, payload)
      ledger = KnowledgeRuntimeAction.find_by(event_id: grant['event_id'], agent_id: proof['agent_id'], action_id: proof['action_id'])
      if ledger
        raise Denied unless ledger.body_sha256 == proof['body_sha256'] && ledger.account_scope == grant['account_scope']

        return ledger.result
      end
      result = execute!(conversation, payload)
      KnowledgeRuntimeAction.create!(account_scope: grant['account_scope'], event_id: grant['event_id'], agent_id: proof['agent_id'],
                                     action_id: proof['action_id'], body_sha256: proof['body_sha256'], result: result)
      result
    end

    def self.mutex!(inbox_id)
      value = ApplicationRecord.connection.quote("knowledge-inbox:#{inbox_id}")
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{value}, 0))")
    end

    # schema.rb cannot represent SQL triggers. A database restored from that
    # file alone must not silently execute mutations without writer fencing.
    def self.require_mutex_triggers!
      count = ApplicationRecord.connection.select_value(<<~SQL.squish).to_i
        SELECT count(*) FROM pg_trigger
        WHERE NOT tgisinternal AND tgenabled = 'O' AND (
          (tgrelid = 'agent_bot_inboxes'::regclass AND tgname = 'knowledge_bot_inbox_mutex') OR
          (tgrelid = 'inboxes'::regclass AND tgname = 'knowledge_inbox_parent_mutex') OR
          (tgrelid = 'agent_bots'::regclass AND tgname = 'knowledge_bot_parent_mutex'))
      SQL
      raise Denied unless count == 3
    end

    def self.execute!(conversation, payload)
      case payload['tool']
      when 'labels' then labels!(conversation, payload)
      when 'handoff' then handoff!(conversation, payload)
      when 'pipeline' then pipeline!(conversation, payload)
      else raise Denied
      end
    end

    def self.labels!(conversation, payload)
      raise Denied unless (payload.keys - %w[tool action labels]).empty?
      return { 'status' => 'success', 'labels' => conversation.label_list.to_a } if payload['action'] == 'list'

      labels = resolved_labels!(payload['labels'])

      case payload['action']
      when 'add' then conversation.add_labels(labels)
      when 'remove' then conversation.remove_labels(labels)
      else raise Denied
      end
      { 'status' => 'success', 'labels' => conversation.label_list.to_a }
    end

    def self.resolved_labels!(values)
      raise Denied unless values.is_a?(Array) && values.length <= 30

      values.map do |value|
        raise Denied unless value.is_a?(String) && value.length <= 80

        label_title!(value)
      end
    end

    def self.label_title!(value)
      record = value.match?(BindingSet::UUID) ? Label.find_by(id: value) : Label.find_by(title: value)
      raise Denied unless record

      record.title
    end

    def self.handoff!(conversation, payload)
      raise Denied unless (payload.keys - %w[tool team_id assignee_id]).empty?
      raise Denied unless payload['team_id'].present? ^ payload['assignee_id'].present?

      target = payload['team_id'].presence || payload['assignee_id']
      raise Denied unless target.is_a?(String) && target.match?(BindingSet::UUID)

      if payload['team_id'].present?
        conversation.update!(team: Team.find(payload['team_id']), status: :open)
      else
        conversation.update!(assignee: User.find(payload['assignee_id']), status: :open)
      end
      { 'status' => 'success', 'terminal_handoff' => true }
    end

    def self.pipeline!(conversation, payload)
      validate_pipeline_payload!(payload)

      pipeline = Pipeline.active.find(payload['pipeline_id'])
      stage = pipeline.pipeline_stages.find(payload['stage_id'])
      item = pipeline.pipeline_items.active.where(conversation_id: conversation.id).lock.first
      raise Denied if payload['action'] == 'move_to_stage' && !item

      item ? item.move_to_stage(stage) : pipeline.add_conversation(conversation, stage)
      { 'status' => 'success', 'pipeline_id' => pipeline.id, 'stage_id' => stage.id }
    end

    def self.validate_pipeline_payload!(payload)
      raise Denied unless (payload.keys - %w[tool action pipeline_id stage_id]).empty?
      raise Denied unless %w[add_to_pipeline move_to_stage].include?(payload['action'])
      raise Denied unless %w[pipeline_id stage_id].all? { |field| payload[field].is_a?(String) && payload[field].match?(BindingSet::UUID) }
    end
    private_class_method :mutex!, :require_mutex_triggers!, :execute!, :labels!, :handoff!, :pipeline!, :authorized_action!,
                         :execute_once!, :resolved_labels!, :label_title!, :validate_pipeline_payload!
  end
end
