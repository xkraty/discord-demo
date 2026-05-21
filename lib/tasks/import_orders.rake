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

      # Parse sold price — two formats present in the CSV:
      #   European: "1.095,95" (dot=thousands, comma=decimal)
      #   Plain:    "203.95"   (dot=decimal, no thousands sep)
      # Detect by presence of comma: if comma exists treat as European.
      price_cents = if price_raw.present?
        normalised = if price_raw.include?(",")
          price_raw.gsub(".", "").gsub(",", ".")   # "1.095,95" → "1095.95"
        else
          price_raw.gsub(",", "")                  # "203.95"   → "203.95"
        end
        (normalised.to_f * 100).round
      end

      # Parse date — only store when it's a real date, skip status strings
      ordered_at = nil
      if date_raw =~ /\A\d{1,2}-\d{1,2}-\d{4}\z/
        ordered_at = Date.strptime(date_raw, "%d-%m-%Y") rescue nil
      end

      Order.create!(
        order_number:     order_num.to_i,
        product:          product,
        size:             size,
        sold_price_cents: price_cents,
        ordered_at:       ordered_at
      )
      imported_orders += 1
    rescue ActiveRecord::RecordInvalid => e
      puts "  SKIP row (order #{order_num}): #{e.message}"
      skipped += 1
    end

    puts "Done. Products: #{imported_products} new. Orders: #{imported_orders} imported. Skipped: #{skipped}."
  end
end
