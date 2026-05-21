class Order < ApplicationRecord
  belongs_to :product

  validates :order_number, presence: true
  validates :sold_price_cents, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  def sold_price
    sold_price_cents / 100.0 if sold_price_cents
  end

  def sold_price_display
    return "—" unless sold_price_cents
    "€#{"%.2f" % (sold_price_cents / 100.0)}"
  end
end
