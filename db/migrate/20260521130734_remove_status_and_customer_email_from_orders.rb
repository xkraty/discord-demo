class RemoveStatusAndCustomerEmailFromOrders < ActiveRecord::Migration[8.1]
  def change
    remove_column :orders, :status, :string
    remove_column :orders, :customer_email, :string
  end
end
