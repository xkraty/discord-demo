class CommandsController < ActionController::API
  before_action :authenticate_bearer!

  LONG_POLL_TIMEOUT = 25.seconds
  LONG_POLL_INTERVAL = 0.5.seconds

  # GET /commands
  # Long-polls for the next pending outbound command. Returns 200 with the
  # command JSON when one is available, or 204 after LONG_POLL_TIMEOUT with
  # no body. The extension loops immediately on 200 and after a brief pause on 204.
  def next_command
    deadline = Time.current + LONG_POLL_TIMEOUT

    loop do
      cmd = OutboundMessage.pending.first
      if cmd
        render json: {
          command_id:  cmd.id,
          kind:        "send_message",
          channel_id:  cmd.discord_channel_id,
          body:        cmd.body,
        }
        return
      end
      break if Time.current >= deadline
      sleep LONG_POLL_INTERVAL
    end

    head :no_content
  end

  # POST /commands/:id/ack
  # Called by the extension after it attempts delivery.
  # Marks the command as sent (ok) or leaves it pending (not ok, so it retries).
  def ack
    cmd = OutboundMessage.find_by(id: params[:id])
    return head :not_found unless cmd

    if params[:ok].in?([true, "true", 1, "1"])
      cmd.update!(sent_at: Time.current)
    end

    head :ok
  end

  private

  def authenticate_bearer!
    expected = Rails.application.credentials.capture_api_key.to_s
    token = request.headers["Authorization"].to_s.delete_prefix("Bearer ").strip
    return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)
    head :unauthorized
  end
end
