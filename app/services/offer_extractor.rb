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

    Every offer must include all four fields: sku, name, size, price. Use an
    empty string "" for any value you don't know — never guess or invent one.

    Messages may be in Italian. If a message contains no offer (a greeting or
    small talk like "ciao"), return an empty offers array.
  PROMPT

  class MissingApiKey < StandardError; end

  # After #call, these hold the raw response so the test page can show it:
  #   raw_content — the parsed JSON the model returned (Hash), or the raw String
  #   usage       — { input:, output:, total:, model:, cost: } counts; cost is
  #                 USD (Float) or nil if pricing for the model is unknown
  attr_reader :raw_content, :usage

  # system_prompt: lets the test page override the default instructions. Falls
  # back to SYSTEM_PROMPT when blank.
  def initialize(message, system_prompt: nil)
    @message       = message.to_s.strip
    @system_prompt = system_prompt.presence || SYSTEM_PROMPT
  end

  def call
    return [] if @message.blank?
    raise MissingApiKey, "OpenAI API key is not configured" if RubyLLM.config.openai_api_key.blank?

    response = RubyLLM.chat
                      .with_model(MODEL)
                      .with_temperature(0)
                      .with_instructions(@system_prompt)
                      .with_schema(OfferSchema)
                      .ask(@message)

    @raw_content = response.content
    @usage = {
      input:  response.input_tokens,
      output: response.output_tokens,
      total:  response.input_tokens.to_i + response.output_tokens.to_i,
      model:  response.model_id,
      cost:   response.cost&.total # USD; nil if model pricing is unknown
    }

    # With a schema set, response.content is parsed JSON (a Hash with string keys).
    offers = @raw_content.is_a?(Hash) ? @raw_content["offers"] : nil
    Array(offers).map { |o| o.symbolize_keys }
  end
end
