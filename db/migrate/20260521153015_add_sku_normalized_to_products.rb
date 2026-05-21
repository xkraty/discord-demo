class AddSkuNormalizedToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :sku_normalized, :string
    add_index  :products, :sku_normalized
  end
end
