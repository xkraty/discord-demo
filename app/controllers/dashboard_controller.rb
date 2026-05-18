class DashboardController < ApplicationController
  before_action :authenticate_dashboard!

  def show
    @messages = DiscordMessage.dms.where(event_type: "MESSAGE_CREATE").limit(100)
    @last_session_event = DiscordSessionEvent.recent.first
    @last_message_at    = DiscordMessage.dms.maximum(:captured_at)
    @gateways_open      = DiscordSessionEvent
                            .where(event: %w[gateway_open gateway_close])
                            .order(occurred_at: :desc)
                            .limit(50)
                            .group_by(&:ws_id)
                            .count { |_ws, events| events.first&.event == "gateway_open" }
  end
end
