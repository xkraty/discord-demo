# Renders the conversation thread for a single Discord channel as a Turbo
# Frame the dashboard swaps into its drawer.
#
# GET /channels/:discord_channel_id
#
# - Reverse-chronological in DB (newest first), but rendered in chronological
#   order in the view so the drawer reads top→bottom like a chat (newest at
#   the bottom).
# - Live updates: the view subscribes to `channel:<id>` Turbo Stream and
#   appends new MESSAGE_CREATE rows as they arrive.
class ChannelThreadsController < ApplicationController
  before_action :authenticate_dashboard!

  THREAD_LIMIT = 200

  def show
    @discord_channel_id = params[:discord_channel_id]
    @channel = Channel.find_by(discord_channel_id: @discord_channel_id)

    # Pull the last N MESSAGE_CREATE rows for this channel, then reverse so
    # the view renders oldest→newest (Discord-style scrollback).
    @messages = DiscordMessage
                  .where(discord_channel_id: @discord_channel_id, event_type: "MESSAGE_CREATE")
                  .order(captured_at: :desc)
                  .limit(THREAD_LIMIT)
                  .reverse
  end
end
