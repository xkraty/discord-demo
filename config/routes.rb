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
end
