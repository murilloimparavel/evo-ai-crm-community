module AgentBots
  class SessionSyncContactPayload
    def initialize(contact)
      @contact = contact
    end

    def build
      identity_data.merge(profile_data).merge(relationship_data)
    end

    private

    def identity_data
      {
        id: @contact.id.to_s,
        name: @contact.name,
        email: @contact.email,
        phone_number: @contact.phone_number,
        identifier: @contact.identifier,
        type: @contact.type,
        contact_type: @contact.contact_type,
        blocked: @contact.blocked
      }
    end

    def profile_data
      {
        location: @contact.location,
        country_code: @contact.country_code,
        industry: @contact.industry,
        website: @contact.website,
        tax_id: @contact.tax_id,
        last_activity_at: @contact.last_activity_at&.iso8601,
        created_at: @contact.created_at&.iso8601,
        updated_at: @contact.updated_at&.iso8601,
        additional_attributes: @contact.additional_attributes || {},
        custom_attributes: @contact.custom_attributes || {}
      }
    end

    def relationship_data
      {
        labels: @contact.labels.pluck(:name),
        companies: @contact.companies.map { |company| { id: company.id.to_s, name: company.name } },
        pipelines: pipeline_data
      }
    end

    def pipeline_data
      @contact.pipeline_items.includes(:pipeline, :pipeline_stage, :tasks).map do |item|
        build_pipeline_item(item)
      end
    end

    def build_pipeline_item(item)
      pipeline_record(item).merge(stage_record(item)).merge(task_record(item))
    end

    def pipeline_record(item)
      { id: item.id.to_s, pipeline_id: item.pipeline_id.to_s, pipeline_name: item.pipeline&.name }
    end

    def stage_record(item)
      {
        stage_id: item.pipeline_stage_id.to_s,
        stage_name: item.pipeline_stage&.name,
        stage_position: item.pipeline_stage&.position,
        status: item.completed? ? 'completed' : 'pending',
        entered_at: item.entered_at&.iso8601,
        completed_at: item.completed_at&.iso8601
      }
    end

    def task_record(item)
      {
        custom_fields: item.custom_fields || {},
        tasks: item.tasks.map { |task| { id: task.id.to_s, title: task.title, status: task.status } }
      }
    end
  end
end
