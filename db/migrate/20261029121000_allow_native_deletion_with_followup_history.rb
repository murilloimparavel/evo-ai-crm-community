class AllowNativeDeletionWithFollowupHistory < ActiveRecord::Migration[7.1]
  # Operational targets may disappear through existing CRM deletion flows.
  # Keep the execution/evidence/billing ledger; only its live links are nulled.
  def up
    links = {
      followup_campaigns: { pipeline_stage_id: :pipeline_stages, inbox_id: :inboxes },
      followup_templates: { approved_by_id: :users },
      followup_anchor_evidences: { conversation_id: :conversations, pipeline_item_id: :pipeline_items,
                                 source_incoming_message_id: :messages, anchor_message_id: :messages, verified_by_id: :users },
      followup_classifications: { conversation_id: :conversations, source_incoming_message_id: :messages },
      followup_executions: { conversation_id: :conversations, pipeline_item_id: :pipeline_items,
                             source_incoming_message_id: :messages, quote_anchor_message_id: :messages, message_id: :messages }
    }
    links.each do |table, columns|
      columns.each do |column, target|
        remove_foreign_key table, column: column if foreign_key_exists?(table, column: column)
        change_column_null table, column, true
        # Earlier schemas intentionally had no FK for some ledger references.
        # Null any already-missing target before adding the safe live link.
        execute "UPDATE #{table} SET #{column} = NULL WHERE #{column} IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #{target} WHERE #{target}.id = #{table}.#{column})"
        add_foreign_key table, target, column: column, on_delete: :nullify
      end
    end
    remove_foreign_key :followup_conversation_states, column: :conversation_id
    add_foreign_key :followup_conversation_states, :conversations, column: :conversation_id, on_delete: :cascade
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Historical references may already have been nulled; restore must not invent deleted CRM targets'
  end
end
