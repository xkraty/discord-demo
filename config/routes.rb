Rails.application.routes.draw do
  # Health endpoint for the Kamal proxy. Returns 200 if the app boots cleanly.
  get "up" => "rails/health#show", as: :rails_health_check

  # Ingest endpoint for the Chrome extension. Bearer-authed, no CSRF (the
  # controller is an ActionController::API subclass).
  namespace :capture do
    post "ingest", to: "ingest#create"
  end

  # Operator dashboard (basic-auth gated, built in step 6).
  root to: "dashboard#show"

  resources :products, only: %i[index show]
  resources :orders,   only: %i[index]

  get  "search_test",  to: "search_test#index"
  post "search_test",  to: "search_test#query"

  get  "matcher",      to: "matcher#index"
  post "matcher",      to: "matcher#analyze"

  # Conversation thread drawer: GET /channels/:discord_channel_id renders
  # the last N messages from that Discord channel into a Turbo Frame so the
  # dashboard can swap it in as a side drawer. URL-encoded to allow the
  # channel id to contain any character Discord uses (it's a snowflake but
  # we don't validate the shape — leaving it open is safer).
  get "channels/:discord_channel_id",
      to:           "channel_threads#show",
      constraints:  { discord_channel_id: %r{[^/]+} },
      as:           :channel_thread
end
