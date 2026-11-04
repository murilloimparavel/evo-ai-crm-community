require 'time'

class Public::Api::V1::Inboxes::MessagesController < Public::Api::V1::InboxesController
  before_action :authenticate_stays_bridge!, only: [:import]
  before_action :set_message, only: [:update]

  def index
    @messages = @conversation.nil? ? [] : message_finder.perform
  end

  def create
    @message = @conversation.messages.new(message_params)
    build_attachment
    @message.save!
  end

  # Imports a message already exchanged by an external channel. source_id is
  # the idempotency key, so a bridge can safely reconcile a timed-out POST.
  def import
    return render json: { error: 'Conversation not found' }, status: :not_found if @conversation.nil?

    unless valid_import_params?
      return render json: { error: 'content, source_id, message_type and external_created_at are required' },
                    status: :unprocessable_entity
    end

    @message = @conversation.messages.find_by(source_id: import_params[:source_id])
    @message ||= @conversation.with_lock do
      @conversation.messages.find_by(source_id: import_params[:source_id]) || @conversation.messages.create!(import_message_params)
    end
    render json: serialized_import_message, status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    render json: { error: 'You cannot update the CSAT survey after 14 days' }, status: :unprocessable_entity and return if check_csat_locked

    @message.update!(message_update_params)
  rescue StandardError => e
    render json: { error: @contact.errors, message: e.message }.to_json, status: :internal_server_error
  end

  private

  def build_attachment
    return if params[:attachments].blank?

    params[:attachments].each do |uploaded_attachment|
      @message.attachments.new(
        file_type: helpers.file_type(uploaded_attachment&.content_type),
        file: uploaded_attachment
      )
    end
  end

  def message_finder_params
    {
      filter_internal_messages: true,
      before: params[:before]
    }
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, message_finder_params)
  end

  def message_update_params
    params.permit(submitted_values: [:name, :title, :value, { csat_survey_response: [:feedback_message, :rating] }])
  end

  def permitted_params
    params.permit(:content, :echo_id)
  end

  def set_message
    @message = @conversation.messages.find(params[:id])
  end

  def message_params
    {
      sender: @contact_inbox.contact,
      content: permitted_params[:content],
      inbox_id: @conversation.inbox_id,
      echo_id: permitted_params[:echo_id],
      message_type: :incoming
    }
  end

  def import_message_params
    {
      sender: nil,
      content: import_params[:content],
      inbox_id: @conversation.inbox_id,
      message_type: import_params[:message_type],
      source_id: import_params[:source_id],
      source: :imported,
      content_attributes: { external_created_at: import_params[:external_created_at] },
      created_at: parsed_external_created_at
    }
  end

  def import_params
    @import_params ||= params.permit(:content, :source_id, :message_type, :external_created_at)
  end

  def valid_import_params?
    import_params[:content].present? && import_params[:source_id].present? &&
      %w[incoming outgoing].include?(import_params[:message_type]) && parsed_external_created_at.present?
  rescue ArgumentError, TypeError
    false
  end

  def parsed_external_created_at
    @parsed_external_created_at ||= Time.iso8601(import_params[:external_created_at].to_s)
  end

  def authenticate_stays_bridge!
    return render json: { error: 'Conversation not found' }, status: :not_found if @conversation.nil?

    attributes = @conversation.custom_attributes || {}
    channel = attributes['stays_channel'] || attributes[:stays_channel]
    managed = attributes['stays_bridge_managed'] || attributes[:stays_bridge_managed]
    env_key = { 'airbnb' => 'STAYS_BRIDGE_AIRBNB_IMPORT_TOKEN',
                'bookingcom' => 'STAYS_BRIDGE_BOOKINGCOM_IMPORT_TOKEN',
                'expedia' => 'STAYS_BRIDGE_EXPEDIA_IMPORT_TOKEN' }[channel]
    expected = env_key && ENV[env_key].to_s
    provided = request.headers['X-Stays-Bridge-Token'].to_s
    return if managed == true && expected.present? && secure_token_match?(expected, provided)

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def secure_token_match?(expected, provided)
    expected.bytesize == provided.bytesize && ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end

  def serialized_import_message
    {
      id: @message.id,
      content: @message.content,
      message_type: @message.message_type,
      source_id: @message.source_id,
      external_created_at: @message.external_created_at,
      conversation_id: @conversation.display_id,
      created_at: @message.created_at
    }
  end

  def check_csat_locked
    (Time.zone.now.to_date - @message.created_at.to_date).to_i > 14 and @message.content_type == 'input_csat'
  end
end
