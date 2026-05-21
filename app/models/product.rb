class Product < ApplicationRecord
  has_many :orders

  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true

  # Full-text search across SKU + name via Postgres tsvector.
  # Uses plainto_tsquery so multi-word queries like "cream nyc" just work.
  def self.search(query)
    return none if query.blank?
    # Use 'english' so stems match: "travis"→"travi", "canary"→"canari".
    # SKU tokens survive because they're not real English words and pass through unchanged.
    where("search_vector @@ plainto_tsquery('english', ?)", query)
      .order(Arel.sql("ts_rank(search_vector, plainto_tsquery('english', #{connection.quote(query)})) DESC"))
  end
end
