# frozen_string_literal: true

require "sqlite3"
require "json"

module DB
  DB_PATH = File.expand_path("../../data/messages.sqlite3", __FILE__)

  SCHEMA = <<~SQL
    CREATE TABLE IF NOT EXISTS messages (
      id                  INTEGER PRIMARY KEY AUTOINCREMENT,
      discord_message_id  TEXT NOT NULL,
      discord_channel_id  TEXT NOT NULL,
      discord_author_id   TEXT,
      author_username     TEXT,
      author_display_name TEXT,
      event_type          TEXT NOT NULL,
      content             TEXT,
      timestamp_iso       TEXT,
      is_dm               INTEGER NOT NULL,
      raw_payload         TEXT NOT NULL,
      captured_at         TEXT NOT NULL,
      UNIQUE (discord_message_id, event_type)
    );
    CREATE INDEX IF NOT EXISTS idx_messages_channel  ON messages (discord_channel_id);
    CREATE INDEX IF NOT EXISTS idx_messages_author   ON messages (discord_author_id);
    CREATE INDEX IF NOT EXISTS idx_messages_captured ON messages (captured_at);
    CREATE TABLE IF NOT EXISTS session_events (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      event       TEXT NOT NULL,
      detail      TEXT,
      occurred_at TEXT NOT NULL
    );
  SQL

  def self.connection
    @connection ||= begin
      db = SQLite3::Database.new(DB_PATH)
      db.results_as_hash = true
      db.execute("PRAGMA journal_mode=WAL")
      db.execute("PRAGMA foreign_keys=ON")
      db
    end
  end

  def self.init!
    SCHEMA.split(";").map(&:strip).reject(&:empty?).each do |stmt|
      connection.execute(stmt)
    end
  end

  def self.insert_event(event_type:, payload:)
    d           = payload
    captured_at = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

    connection.execute(
      <<~SQL,
        INSERT OR IGNORE INTO messages
          (discord_message_id, discord_channel_id, discord_author_id,
           author_username, author_display_name, event_type,
           content, timestamp_iso, is_dm, raw_payload, captured_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        d["id"],
        d["channel_id"],
        d.dig("author", "id"),
        d.dig("author", "username"),
        d.dig("author", "global_name") || d.dig("author", "display_name"),
        event_type,
        d["content"],
        d["timestamp"],
        d["guild_id"].nil? ? 1 : 0,
        JSON.generate(d),
        captured_at
      ]
    )
  end

  def self.record_session_event(event, detail)
    occurred_at = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    connection.execute(
      "INSERT INTO session_events (event, detail, occurred_at) VALUES (?, ?, ?)",
      [event.to_s, detail&.to_s, occurred_at]
    )
  end
end
