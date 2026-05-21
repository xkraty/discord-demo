# JSON schema for gpt-4o-mini structured output. Describes the shape OfferExtractor
# expects back: a list of offers, each one product+size the seller is offering.
# sku/name are optional because a message may carry only one of them.
class OfferSchema < RubyLLM::Schema
  array :offers, description: "One entry per product+size the seller is offering. Empty if the message contains no offer." do
    object do
      string :sku,   required: false, description: "Product SKU / style code, e.g. DZ4137-700 or VN000E8VFST. Omit if not present."
      string :name,  required: false, description: "Product name if the seller described it in words instead of a SKU, e.g. 'velvet brown'. Omit if a SKU is given."
      string :size,  required: false, description: "EU size, e.g. 42 or 44.5. Omit if not stated."
      string :price, required: false, description: "Asking price as a number, e.g. 380. Omit if not stated."
    end
  end
end
