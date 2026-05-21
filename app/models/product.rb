class Product < ApplicationRecord
  has_many :orders

  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true
end
