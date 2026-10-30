class CreateModularFollowups < ActiveRecord::Migration[7.1]
  # Keep the reversible schema migration intact; final FK semantics were independently compared.
  def change # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    create_table :followup_campaigns, id: :uuid do |t|
      t.references :pipeline_stage, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :inbox, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :campaign_key, null: false
      t.string :engine, null: false, default: 'jev_v1'
      t.string :policy_version, null: false
      t.boolean :enabled, null: false, default: false
      t.string :mode, null: false, default: 'off'
      t.datetime :active_from
      t.datetime :expires_at
      t.jsonb :policy, null: false, default: {}
      t.timestamps
    end
    add_index :followup_campaigns, :campaign_key, unique: true
    add_index :followup_campaigns, [:pipeline_stage_id, :inbox_id], unique: true, where: 'enabled = TRUE',
                                                                    name: 'idx_followup_campaign_enabled_target'

    create_table :followup_templates, id: :uuid do |t|
      t.string :template_key, null: false
      t.string :version, null: false
      t.text :body, null: false
      t.string :body_digest
      t.references :approved_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :approved_at
      t.boolean :active, null: false, default: false
      t.timestamps
    end
    add_index :followup_templates, [:template_key, :version], unique: true

    create_table :followup_anchor_evidences, id: :uuid do |t|
      t.references :followup_campaign, type: :uuid, null: false, foreign_key: true
      t.references :conversation, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :pipeline_item, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :source_incoming_message, type: :uuid, foreign_key: { to_table: :messages, on_delete: :nullify }
      t.references :anchor_message, type: :uuid, foreign_key: { to_table: :messages, on_delete: :nullify }
      t.references :verified_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :evidence_method, null: false, default: 'operator_verified'
      t.string :anchor_digest, null: false
      t.datetime :verified_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index(
      :followup_anchor_evidences,
      [:followup_campaign_id, :conversation_id, :source_incoming_message_id, :anchor_message_id],
      unique: true, name: 'idx_followup_evidence_identity'
    )

    create_table :followup_conversation_states, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.bigint :revision, null: false, default: 0
      t.bigint :classification_generation, null: false, default: 0
      t.uuid :latest_incoming_message_id
      t.datetime :classification_due_at
      t.datetime :cooldown_until
      t.uuid :active_execution_id
      t.timestamps
    end
    add_index :followup_conversation_states, :classification_due_at

    create_table :followup_classifications, id: :uuid do |t|
      t.references :followup_campaign, type: :uuid, null: false, foreign_key: true
      t.references :conversation, type: :uuid, foreign_key: { on_delete: :nullify }
      t.uuid :source_incoming_message_id
      t.bigint :generation, null: false
      t.bigint :revision, null: false
      t.string :policy_version, null: false
      t.string :model, null: false
      t.string :question_version, null: false
      t.string :status, null: false, default: 'reserved'
      t.string :snapshot_hash
      t.jsonb :decision, null: false, default: {}
      t.string :reason
      t.integer :attempt_count, null: false, default: 0
      t.bigint :fence_token, null: false, default: 0
      t.datetime :lease_expires_at
      t.datetime :expires_at
      t.datetime :next_attempt_at
      t.bigint :input_tokens
      t.timestamps
    end
    add_index :followup_classifications, [:followup_campaign_id, :conversation_id, :generation, :policy_version, :model, :question_version],
              unique: true, name: 'idx_followup_classification_cycle'
    add_index :followup_classifications, [:status, :next_attempt_at], name: 'idx_followup_classification_retry'

    create_table :followup_executions, id: :uuid do |t|
      t.references :followup_campaign, type: :uuid, null: false, foreign_key: true
      t.references :conversation, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :pipeline_item, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :followup_anchor_evidence, type: :uuid, null: false, foreign_key: true
      t.uuid :source_incoming_message_id
      t.uuid :quote_anchor_message_id
      t.string :step_id, null: false
      t.string :policy_version, null: false
      t.string :status, null: false, default: 'reserved'
      t.string :snapshot_hash
      t.string :model
      t.string :question_version
      t.string :decision
      t.string :reason
      t.uuid :template_id
      t.datetime :due_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :next_attempt_at
      t.datetime :lease_expires_at
      t.bigint :fence_token, null: false, default: 0
      t.bigint :authorized_revision
      t.integer :attempt_count, null: false, default: 0
      t.bigint :input_tokens
      t.uuid :message_id
      t.string :external_provider_id
      t.datetime :finalized_at
      t.timestamps
    end
    add_index(
      :followup_executions,
      [:followup_campaign_id, :conversation_id, :source_incoming_message_id, :step_id],
      unique: true, name: 'idx_followup_execution_cycle_step'
    )
    add_index :followup_executions, [:status, :due_at], name: 'idx_followup_execution_due'
    add_index :followup_executions, :message_id, unique: true
    add_reference :messages, :followup_execution, type: :uuid, foreign_key: true, index: { unique: true }

    create_table :followup_budget_days, id: :uuid do |t|
      t.string :scope_key, null: false
      t.date :budget_date, null: false
      t.string :timezone, null: false
      t.decimal :reserved_usd, precision: 18, scale: 10, null: false, default: 0
      t.decimal :spent_usd, precision: 18, scale: 10, null: false, default: 0
      t.integer :conversation_count, null: false, default: 0
      t.jsonb :conversation_ids, null: false, default: []
      t.timestamps
    end
    add_index :followup_budget_days, [:scope_key, :budget_date], unique: true
    create_table :followup_budget_reservations, id: :uuid do |t|
      t.references :followup_budget_day, type: :uuid, null: false, foreign_key: true
      t.string :subject_type, null: false
      t.uuid :subject_id, null: false
      t.integer :attempt_number, null: false
      t.decimal :reserved_usd, precision: 18, scale: 10, null: false
      t.decimal :actual_usd, precision: 18, scale: 10
      t.bigint :input_tokens
      t.string :status, null: false, default: 'reserved'
      t.timestamps
    end
    add_index :followup_budget_reservations, [:subject_type, :subject_id, :attempt_number], unique: true, name: 'idx_followup_budget_attempt'
  end
end
