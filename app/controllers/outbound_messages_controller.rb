class OutboundMessagesController < ApplicationController
  before_action :authenticate_dashboard!

  def create
    msg = OutboundMessage.new(
      discord_channel_id: params[:discord_channel_id],
      body:               params[:body].to_s.strip,
      queued_at:          Time.current
    )

    if msg.save
      head :created
    else
      render json: { errors: msg.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
