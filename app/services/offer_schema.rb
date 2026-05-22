# JSON schema for gpt-4o-mini structured output. Describes the shape OfferExtractor
# expects back: a list of offers, each one product+size the seller is offering.
#
# NOTE: OpenAI strict structured output requires EVERY property to be listed in
# `required` — optional fields are not allowed. So all fields are required and the
# model is instructed (in OfferExtractor::SYSTEM_PROMPT) to use an empty string ""
# for any value it doesn't know.
class OfferSchema < RubyLLM::Schema
  array :offers, description: "One entry per product+size the seller is offering. Empty if the message contains no offer." do
    object do
      string :sku,   description: "Product SKU / style code, e.g. DZ4137-700 or VN000E8VFST. Empty string if not present."
      string :name,  description: "Product name if the seller described it in words instead of a SKU, e.g. 'velvet brown'. Empty string if a SKU is given."
      string :size,  description: "EU size, e.g. 42 or 44.5. Empty string if not stated."
      string :price, description: "Asking price as a number, e.g. 380. Empty string if not stated."
    end
  end
end
