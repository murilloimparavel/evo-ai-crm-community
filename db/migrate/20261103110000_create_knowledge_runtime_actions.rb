class CreateKnowledgeRuntimeActions < ActiveRecord::Migration[7.1]
  MUTEX_SQL = <<~SQL.squish
    CREATE FUNCTION knowledge_action_lock_bot_inbox() RETURNS trigger AS $$
    DECLARE scoped_id text;
    BEGIN
      FOR scoped_id IN
        SELECT DISTINCT value FROM unnest(ARRAY[
          CASE WHEN TG_OP <> 'INSERT' THEN OLD.inbox_id::text END,
          CASE WHEN TG_OP <> 'DELETE' THEN NEW.inbox_id::text END
        ]) AS value WHERE value IS NOT NULL ORDER BY value
      LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended('knowledge-inbox:' || scoped_id, 0));
      END LOOP;
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    CREATE TRIGGER knowledge_bot_inbox_mutex BEFORE INSERT OR UPDATE OR DELETE ON agent_bot_inboxes
      FOR EACH ROW EXECUTE FUNCTION knowledge_action_lock_bot_inbox();
    CREATE FUNCTION knowledge_action_lock_bot_parent() RETURNS trigger AS $$
    DECLARE scoped_id text;
    BEGIN
      IF TG_TABLE_NAME = 'inboxes' THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('knowledge-inbox:' || OLD.id::text, 0));
      ELSE
        FOR scoped_id IN SELECT DISTINCT inbox_id::text FROM agent_bot_inboxes
          WHERE agent_bot_id = OLD.id ORDER BY inbox_id::text
        LOOP
          PERFORM pg_advisory_xact_lock(hashtextextended('knowledge-inbox:' || scoped_id, 0));
        END LOOP;
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    CREATE TRIGGER knowledge_inbox_parent_mutex BEFORE UPDATE OR DELETE ON inboxes
      FOR EACH ROW EXECUTE FUNCTION knowledge_action_lock_bot_parent();
    CREATE TRIGGER knowledge_bot_parent_mutex BEFORE UPDATE OR DELETE ON agent_bots
      FOR EACH ROW EXECUTE FUNCTION knowledge_action_lock_bot_parent();
  SQL

  def up
    create_table :knowledge_runtime_actions, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.string :account_scope, null: false
      t.uuid :event_id, null: false
      t.uuid :agent_id, null: false
      t.uuid :action_id, null: false
      t.string :body_sha256, null: false
      t.jsonb :result, null: false, default: {}
      t.timestamps
    end
    add_index :knowledge_runtime_actions, [:event_id, :agent_id, :action_id], unique: true, name: :idx_knowledge_action_identity
    # A database trigger covers ORM, bulk SQL and asynchronous deletion alike.
    # Readers acquire the same advisory mutex before validating the assignment.
    execute MUTEX_SQL
  end

  def down
    execute 'DROP TRIGGER knowledge_bot_inbox_mutex ON agent_bot_inboxes'
    execute 'DROP TRIGGER knowledge_inbox_parent_mutex ON inboxes'
    execute 'DROP TRIGGER knowledge_bot_parent_mutex ON agent_bots'
    execute 'DROP FUNCTION knowledge_action_lock_bot_parent()'
    execute 'DROP FUNCTION knowledge_action_lock_bot_inbox()'
    drop_table :knowledge_runtime_actions
  end
end
