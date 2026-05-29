class OutboundMessage < ApplicationRecord
  validates :discord_channel_id, :body, presence: true
  validates :body, length: { maximum: 2000 }

  scope :pending, -> { where(sent_at: nil).order(:queued_at) }
end
