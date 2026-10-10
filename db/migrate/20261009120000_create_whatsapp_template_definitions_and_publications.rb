# frozen_string_literal: true

class CreateWhatsappTemplateDefinitionsAndPublications < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_template_definitions, id: :uuid do |t|
      t.string :name, null: false
      t.string :language, null: false, default: 'pt_BR'
      t.string :category, null: false
      t.text :content, null: false
      t.jsonb :components, null: false, default: []
      t.jsonb :variables, null: false, default: []
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :whatsapp_template_definitions, [:name, :language], unique: true,
              name: 'idx_wa_template_definitions_name_language'

    create_table :whatsapp_template_publications, id: :uuid do |t|
      t.references :whatsapp_template_definition, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade, name: 'fk_wa_template_publications_definition' },
                   index: { name: 'idx_wa_tpl_pubs_definition' }
      t.string :waba_id, null: false
      t.string :external_template_id
      t.string :status, null: false, default: 'not_submitted'
      t.string :raw_status
      t.string :meta_category
      t.string :quality
      t.text :rejected_reason
      t.text :operational_error
      t.jsonb :meta_data, null: false, default: {}
      t.datetime :submitted_at
      t.datetime :synced_at
      t.timestamps
    end
    add_index :whatsapp_template_publications, [:whatsapp_template_definition_id, :waba_id],
              unique: true, name: 'idx_wa_tpl_pubs_definition_waba'
    add_index :whatsapp_template_publications, [:waba_id, :external_template_id],
              unique: true, where: 'external_template_id IS NOT NULL', name: 'idx_wa_tpl_pubs_waba_external'
    add_index :whatsapp_template_publications, [:waba_id, :status], name: 'idx_wa_tpl_pubs_waba_status'
  end
end
