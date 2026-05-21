class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.string :sku, null: false
      t.string :name, null: false

      t.timestamps
    end
    add_index :products, :sku, unique: true
  end
end
