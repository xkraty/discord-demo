module Capture
  # POST /capture/ingest
  #
  # Body (JSON):
  #   {batch_id, client, events: [...]}
  #
  # Headers:
  #   Authorization: Bearer <Rails.application.credentials.capture_api_key>
  #
  # Returns:
  #   200 {ok: true, accepted: N, failed: M, batch_id: "..."}
  #   401 if Authorization is missing/wrong
  #   400 if the JSON body is malformed or missing :events
  #
  # ActionController::API is used (not ApplicationController) to skip CSRF,
  # the view layer, and any future before_action stack we add to the
  # human-facing dashboard.
  class IngestController < ActionController::API
    before_action :authenticate_bearer!

    def create
      events = params[:events]
      return render json: { error: "events_required" }, status: :bad_request unless events.is_a?(Array)

      accepted = 0
      failed   = 0

      # Per-event try/rescue: a poison event records its error but doesn't
      # spoil the rest of the batch. Each call wraps its own transaction in
      # the service so partial success is durable.
      events.each do |event|
        begin
          if CaptureIngestService.new(event.to_unsafe_h).call
            accepted += 1
          end
        rescue => e
          failed += 1
          Rails.logger.warn(
            "[capture] ingest_event_failed err=#{e.class} msg=#{e.message.slice(0, 200)}"
          )
        end
      end

      render json: {
        ok:        true,
        accepted:  accepted,
        failed:    failed,
        batch_id:  params[:batch_id]
      }
    end

    private

    def authenticate_bearer!
      header = request.headers["Authorization"].to_s
      token  = header.start_with?("Bearer ") ? header[7..] : nil

      expected = Rails.application.credentials.capture_api_key.to_s
      if token.nil? || expected.empty? ||
         !ActiveSupport::SecurityUtils.secure_compare(token, expected)
        head :unauthorized
      end
    end
  end
end
