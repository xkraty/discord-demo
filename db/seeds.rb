# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

csv_path = Rails.root.join("db/seeds/orders.csv")
if csv_path.exist?
  Rake::Task["import:orders"].invoke(csv_path.to_s)
else
  puts "Seed CSV not found at #{csv_path} — skipping order import."
end
