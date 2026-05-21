require "ruby_llm"
require "ruby_llm/schema" # separate gem — provides RubyLLM::Schema for structured output

# OpenAI key lives in Rails credentials (same convention as capture_api_key /
# basic_auth). Blank until the client's key is added via `bin/rails
# credentials:edit`; OfferExtractor guards the blank case so the app still boots.
RubyLLM.configure do |config|
  config.openai_api_key = Rails.application.credentials.openai_api_key
end
