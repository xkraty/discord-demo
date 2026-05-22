class MatcherController < ApplicationController
  before_action :authenticate_dashboard!

  # A few seller-style messages to one-click into the box.
  EXAMPLES = [
    "DZ4137-700 43 390\nDM7866-200 40.5 540",
    "velvet brown 42 and 42.5 here 380 each",
    "VN000E8VFST- 41x2 - 195+\nVN000E8VFST 44.5 - 200+",
    "ciao come stai"
  ].freeze

  def index
    @examples      = EXAMPLES
    @system_prompt = OfferExtractor::SYSTEM_PROMPT
  end

  def analyze
    @examples      = EXAMPLES
    @raw_message   = params[:message].to_s.strip
    # Editable on the page; fall back to the default so an empty box still works.
    @system_prompt = params[:system_prompt].presence || OfferExtractor::SYSTEM_PROMPT
    return render :index if @raw_message.blank?

    extractor    = OfferExtractor.new(@raw_message, system_prompt: @system_prompt)
    @offers      = extractor.call
    @raw_content = extractor.raw_content
    @usage       = extractor.usage

    @matches = @offers.map { |offer| offer.merge(search_for(offer)) }

    render :index
  rescue OfferExtractor::MissingApiKey
    @llm_error = "OpenAI API key not configured yet — add it via bin/rails credentials:edit."
    render :index
  rescue RubyLLM::Error => e
    @llm_error = "LLM request failed: #{e.message}"
    render :index
  end

  private

  # Find matching products for an extracted offer. Sellers often give a wrong or
  # garbled SKU but a good product name (or vice versa), so we try the SKU first
  # and FALL BACK TO THE NAME when the SKU finds nothing — rather than only using
  # the name when the SKU is blank. Price/size are never used to search.
  #
  # Returns { products:, matched_on: } where matched_on is :sku, :name, or nil.
  def search_for(offer)
    sku  = offer[:sku].to_s.strip
    name = offer[:name].to_s.strip

    if sku.present?
      products = Product.search(sku).limit(5).to_a
      return { products: products, matched_on: :sku } if products.any?
    end

    if name.present?
      products = Product.search(name).limit(5).to_a
      return { products: products, matched_on: :name } if products.any?
    end

    { products: [], matched_on: nil }
  end
end
