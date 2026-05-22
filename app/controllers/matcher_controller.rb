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

    # Search products by SKU first, fall back to the name. Price/size are NOT
    # search inputs — they ride along on the offer for display.
    @matches = @offers.map do |offer|
      term     = offer[:sku].presence || offer[:name].to_s
      products = term.present? ? Product.search(term).limit(5).to_a : []
      offer.merge(products: products)
    end

    render :index
  rescue OfferExtractor::MissingApiKey
    @llm_error = "OpenAI API key not configured yet — add it via bin/rails credentials:edit."
    render :index
  rescue RubyLLM::Error => e
    @llm_error = "LLM request failed: #{e.message}"
    render :index
  end
end
