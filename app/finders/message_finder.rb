class MessageFinder
  def initialize(conversation, params, includes: nil)
    @conversation = conversation
    @params = params
    @includes = includes
  end

  def perform
    query = Message.where(conversation_id: @conversation.id)
                   .includes(@includes || [:sender, :attachments])

    # Filtrar mensagens internas se necessário
    if @params[:filter_internal_messages].present?
      query = query.where(private: false).where.not(message_type: :activity)
    end

    # Paginação baseada em after/before
    if @params[:after].present?
      after_message = Message.find_by(id: @params[:after])
      if after_message
        query = query.where(
          'created_at > :created_at OR (created_at = :created_at AND id > :id)',
          created_at: after_message.created_at,
          id: after_message.id
        )
      end
    end

    if @params[:before].present?
      before_message = Message.find_by(id: @params[:before])
      if before_message
        query = query.where(
          'created_at < :created_at OR (created_at = :created_at AND id < :id)',
          created_at: before_message.created_at,
          id: before_message.id
        )
      end
    end

    # Aplicar paginação orientada por cursor:
    # - sem cursor: últimas mensagens
    # - before: página anterior
    # - after: novas mensagens após cursor
    limit = limit_for_params
    messages =
      if @params[:before].present? && @params[:after].blank?
        query.reorder(created_at: :desc, id: :desc).limit(limit).to_a.reverse
      elsif @params[:after].present? && @params[:before].blank?
        query.reorder(created_at: :asc, id: :asc).limit(limit).to_a
      elsif @params[:before].blank? && @params[:after].blank?
        query.reorder(created_at: :desc, id: :desc).limit(limit).to_a.reverse
      else
        query.reorder(created_at: :asc, id: :asc).limit(limit).to_a
      end

    # Carregar attachments se não foram incluídos
    unless @includes&.include?(:attachments)
      message_ids = messages.map(&:id)
      attachments_by_message = Attachment.where(attachable_type: 'Message', attachable_id: message_ids)
                                         .group_by(&:attachable_id)

      messages.each do |message|
        message.attachments = attachments_by_message[message.id] || []
      end
    end

    messages
  end

  private

  def limit_for_params
    return 1000 if @params[:after].present? && @params[:before].present?
    return 20 if @params[:before].present?
    return 100 if @params[:after].present?
    20
  end
end
