require "csv"

namespace :import do
  desc "Import products and orders from WTB CSV. Usage: rails 'import:orders[path/to/file.csv]'"
  task :orders, [:csv_path] => :environment do |_, args|
    path = args[:csv_path].presence || Rails.root.join("db/seeds/orders.csv").to_s
    abort "File not found: #{path}" unless File.exist?(path)

    imported_products = 0
    imported_orders   = 0
    skipped           = 0

    CSV.foreach(path, headers: true) do |row|
      sku        = row["SKU"]&.strip
      name       = row["NAME"]&.strip
      order_num  = row["order_n"]&.strip
      size       = row["SIZE"]&.strip
      price_raw  = row["SOLD PRICE"]&.strip
      date_raw   = row["DATE"]&.strip
      email      = row["CUSTOMER EMAIL"]&.strip&.presence

      # Skip rows without the basics
      if sku.blank? || name.blank? || order_num.blank? || order_num !~ /\A\d+\z/
        skipped += 1
        next
      end

      # Upsert product by SKU
      product = Product.find_or_create_by!(sku: sku) do |p|
        p.name = name
      end
      imported_products += 1 if product.previously_new_record?

      # Parse sold price: "1.095,95" → 109595
      price_cents = if price_raw.present?
        price_raw.gsub(".", "").gsub(",", ".").to_f.round * 100
      end

      # Parse date or treat as status string
      ordered_at = nil
      status     = nil
      if date_raw =~ /\A\d{1,2}-\d{1,2}-\d{4}\z/
        begin
          ordered_at = Date.strptime(date_raw, "%d-%m-%Y")
          status = "completed"
        rescue Date::Error
          status = date_raw.downcase
        end
      else
        status = date_raw&.downcase
      end

      Order.create!(
        order_number:    order_num.to_i,
        product:         product,
        size:            size,
        sold_price_cents: price_cents,
        status:          status,
        ordered_at:      ordered_at,
        customer_email:  email
      )
      imported_orders += 1
    rescue ActiveRecord::RecordInvalid => e
      puts "  SKIP row (order #{order_num}): #{e.message}"
      skipped += 1
    end

    puts "Done. Products: #{imported_products} new. Orders: #{imported_orders} imported. Skipped: #{skipped}."
  end
end
