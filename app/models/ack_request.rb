class AckRequest < ApplicationRecord
  scope :pending, -> { where(sent_at: nil).order(:requested_at) }
end
