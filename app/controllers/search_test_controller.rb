class SearchTestController < ApplicationController
  before_action :authenticate_dashboard!

  HAIKU_EXAMPLES = [
    {
      messages: "velvet brown 42 and 42.5 here 380 each",
      offers: [
        { sku: "DM7866-202", size: "42",   price: "380" },
        { sku: "DM7866-202", size: "42.5", price: "380" }
      ]
    },
    {
      messages: "VN000E8VFST- 41x2 - 195+\nVN000E8VFST 44.5 - 200+",
      offers: [
        { sku: "VN000E8VFST", size: "41", price: "195" },
        { sku: "VN000E8VFST", size: "44.5", price: "200" }
      ]
    },
    {
      messages: "DZ4137-700 43 390\nDM7866-200 40.5 540",
      offers: [
        { sku: "DZ4137-700", size: "43",   price: "390" },
        { sku: "DM7866-200", size: "40.5", price: "540" }
      ]
    }
  ].freeze

  def index
    @examples = HAIKU_EXAMPLES
  end

  def query
    @examples  = HAIKU_EXAMPLES
    @raw_query = params[:q].to_s.strip
    return render :index if @raw_query.blank?

    @terms   = extract_search_terms(@raw_query)
    @results = @terms.filter_map do |term|
      products = Product.search(term).limit(5)
      next if products.empty?
      { term: term, products: products.to_a }
    end

    # Deduplicate: keep only the first (highest-ranked) result per product
    seen = Set.new
    @results = @results.filter_map do |r|
      fresh = r[:products].reject { |p| seen.include?(p.id) }
      next if fresh.empty?
      fresh.each { |p| seen << p.id }
      r.merge(products: fresh)
    end

    # Prices: all numbers in the message that look like a price (50–9999)
    @prices = @raw_query.scan(/\d{2,4}(?:[.,]\d{2})?/)
                        .map { |n| n.tr(",", ".").to_f }
                        .select { |n| n >= 50 && n < 10_000 }

    render :index
  end

  private

  def extract_search_terms(text)
    sku_tokens = text.scan(/\b[A-Za-z0-9]{2,}(?:-[A-Za-z0-9]+)+\b/)
                     .concat(text.scan(/\b[A-Z][A-Z0-9]{5,}\b/))
                     .map(&:strip).uniq

    words = text.gsub(/[^a-zA-Z\s]/, " ").split.select { |w| w.length >= 4 }
    name_phrases = words.combination(2).map { |a, b| "#{a} #{b}" }.first(5)

    (sku_tokens + name_phrases).uniq
  end
end
