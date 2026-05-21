class ApplicationController < ActionController::Base
  include Pagy::Method
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses.
  stale_when_importmap_changes

  private

  # HTTP basic auth for the human dashboard. Called explicitly from
  # DashboardController as a before_action — NOT applied globally, because
  # Capture::IngestController uses Bearer auth and inherits from
  # ActionController::API.
  def authenticate_dashboard!
    expected_user = Rails.application.credentials.dig(:basic_auth, :user).to_s
    expected_pass = Rails.application.credentials.dig(:basic_auth, :pass).to_s

    authenticate_or_request_with_http_basic("Discord DM Capture") do |user, pass|
      ActiveSupport::SecurityUtils.secure_compare(user, expected_user) &
        ActiveSupport::SecurityUtils.secure_compare(pass, expected_pass)
    end
  end
end
