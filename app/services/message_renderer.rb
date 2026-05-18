# Substitutes Discord's raw mention tokens in message content with
# human-readable names. Returns an html_safe ActiveSupport::SafeBuffer
# the view can interpolate directly.
#
# Tokens handled:
#   <@id>, <@!id>     user mention      → @<username>  (looked up in mentions[])
#   <@&id>            role mention      → @role:<id>   (raw payload doesn't carry role names)
#   <#id>             channel mention   → #<name>      (Channel table, or #<id> fallback)
#   <:name:id>        custom emoji      → :name:
#   <a:name:id>       animated emoji    → :name:
#   @everyone, @here  literal           → left intact
#
# All non-token text is HTML-escaped. Token substitutions emit small
# styled <span class="mention"> elements so the view can color them
# consistently.
class MessageRenderer
  # Regex captures Discord's mention syntax. The order matters — we run
  # one global scan and dispatch by capture group so we can preserve
  # everything else verbatim.
  TOKEN_RE = /
    <@!?(?<user_id>\d+)>             # user mention
    | <@&(?<role_id>\d+)>            # role mention
    | <\#(?<channel_id>\d+)>         # channel mention
    | <a?:(?<emoji_name>[\w~]+):(?<emoji_id>\d+)> # custom emoji
  /x.freeze

  # Build a renderer for one message. `payload` should be the
  # raw discord `d` hash (so we can read mentions[], channel_id, etc).
  def initialize(payload)
    @payload = payload.is_a?(Hash) ? payload : {}
    @user_index    = build_user_index
    @channel_index = nil  # built lazily on first <#id> hit
  end

  # Render `text` to html_safe HTML with mention substitutions.
  def call(text)
    return ActionController::Base.helpers.sanitize("") if text.blank?

    out = +""
    i = 0
    text.scan(TOKEN_RE) do
      m = Regexp.last_match
      # Emit escaped plain text from `i` up to where the match started.
      out << ERB::Util.html_escape(text[i...m.begin(0)])
      out << render_token(m)
      i = m.end(0)
    end
    # Tail after the last match.
    out << ERB::Util.html_escape(text[i..]) if i < text.length

    out.html_safe
  end

  private

  def build_user_index
    Array(@payload["mentions"]).each_with_object({}) do |u, acc|
      next unless u.is_a?(Hash) && u["id"]
      label = u["global_name"].presence || u["username"].presence || u["id"]
      acc[u["id"].to_s] = label
    end
  end

  def render_token(match)
    if (uid = match[:user_id])
      label = @user_index[uid] || uid
      mention_span("@#{label}")
    elsif (rid = match[:role_id])
      # The raw_payload doesn't carry role names — only mention_roles: [ids].
      # Show the id; a future enhancement could maintain a roles table.
      mention_span("@role:#{rid}")
    elsif (cid = match[:channel_id])
      label = channel_name_for(cid) || cid
      mention_span("##{label.sub(/\A#/, "")}")
    elsif (name = match[:emoji_name])
      # Render as ":name:" — keeps the visual hint that an emoji was
      # there without dragging in the actual image. Could fetch from
      # cdn.discordapp.com/emojis/<id>.png if we wanted to render them.
      emoji_span(":#{name}:")
    end
  end

  def mention_span(label)
    %(<span class="inline-block px-1 -mx-0.5 rounded bg-indigo-50 text-indigo-700 font-medium">#{ERB::Util.html_escape(label)}</span>)
  end

  def emoji_span(label)
    %(<span class="text-slate-500">#{ERB::Util.html_escape(label)}</span>)
  end

  def channel_name_for(cid)
    @channel_index ||= {}
    return @channel_index[cid] if @channel_index.key?(cid)

    @channel_index[cid] = Channel.find_by(discord_channel_id: cid)&.name
  end
end
