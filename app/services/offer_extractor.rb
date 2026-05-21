# Turns a raw seller chat message into structured offers via gpt-4o-mini.
# Returns an array of offer hashes: { sku:, name:, size:, price: } (any key may
# be absent). An empty array means "no offer here" (a greeting, small talk).
#
# Search downstream uses ONLY :sku or :name — :price and :size are carried
# through for display, never used to look up products.
class OfferExtractor
  MODEL = "gpt-4o-mini"

  SYSTEM_PROMPT = <<~PROMPT.freeze
    You extract sneaker/streetwear resale offers from a seller's chat message.

    Return one entry per (product, size) pair the seller is offering, with the
    asking price. SKUs look like DZ4137-700 or VN000E8VFST — copy them exactly,
    never invent or correct them. If the seller names a product in words instead
    of a SKU (e.g. "velvet brown", "nocta glide"), put that in `name`.

    Messages may be in Italian. If a message contains no offer (a greeting or
    small talk like "ciao"), return an empty offers array.
  PROMPT

  class MissingApiKey < StandardError; end

  def initialize(message)
    @message = message.to_s.strip
  end

  def call
    return [] if @message.blank?
    raise MissingApiKey, "OpenAI API key is not configured" if RubyLLM.config.openai_api_key.blank?

    response = RubyLLM.chat
                      .with_model(MODEL)
                      .with_temperature(0)
                      .with_instructions(SYSTEM_PROMPT)
                      .with_schema(OfferSchema)
                      .ask(@message)

    # With a schema set, response.content is parsed JSON (a Hash with string keys).
    offers = response.content.is_a?(Hash) ? response.content["offers"] : nil
    Array(offers).map { |o| o.symbolize_keys }
  end
end
