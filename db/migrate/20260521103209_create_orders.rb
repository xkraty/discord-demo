class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.integer :order_number, null: false
      t.references :product, null: false, foreign_key: true
      t.string :size
      t.integer :sold_price_cents
      t.string :status
      t.date :ordered_at
      t.string :customer_email

      t.timestamps
    end
    add_index :orders, :order_number
    add_index :orders, :customer_email
  end
end
