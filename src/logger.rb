# frozen_string_literal: true

module Log
  def self.info(event, **attrs)
    log("INFO", event, attrs)
  end

  def self.warn(event, **attrs)
    log("WARN", event, attrs)
  end

  private_class_method def self.log(level, event, attrs)
    ts    = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    pairs = attrs.map { |k, v| "#{k}=#{v}" }.join(" ")
    line  = "[#{ts}] [#{level}] #{event}"
    line += " #{pairs}" unless pairs.empty?
    $stdout.puts(line)
    $stdout.flush
  end
end
