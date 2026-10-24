class KnowledgeEntry < ApplicationRecord
  CONTENT_TYPES = %w[faq rule company property].freeze
  STATUSES = %w[draft published archived].freeze

  validates :title, :body, :content_type, presence: true
  validates :content_type, inclusion: { in: CONTENT_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :title, length: { maximum: 250 }
  validates :tags, length: { maximum: 30 }
  validate :tags_are_strings

  scope :published, -> { where(status: 'published') }

  def self.search_published(query, limit: 5)
    limit = limit.to_i.clamp(1, 20)
    published.where(
      "to_tsvector('portuguese', coalesce(title, '') || ' ' || coalesce(body, '')) @@ plainto_tsquery('portuguese', ?)", query
    ).order(Arel.sql("ts_rank(to_tsvector('portuguese', coalesce(title, '') || ' ' || coalesce(body, '')), plainto_tsquery('portuguese', #{connection.quote(query)})) DESC"))
      .limit(limit)
  end

  private

  def tags_are_strings
    errors.add(:tags, 'must contain strings') unless tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) && tag.length <= 80 }
  end
end
