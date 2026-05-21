class ReplaceSkuNormalizedWithSearchVector < ActiveRecord::Migration[8.1]
  def up
    remove_index  :products, :sku_normalized
    remove_column :products, :sku_normalized

    add_column :products, :search_vector, :tsvector

    # Trigger keeps search_vector current on every insert/update
    execute <<~SQL
      CREATE OR REPLACE FUNCTION products_search_vector_update() RETURNS trigger AS $$
      BEGIN
        NEW.search_vector :=
          setweight(to_tsvector('simple', coalesce(NEW.sku, '')), 'A') ||
          setweight(to_tsvector('simple', coalesce(regexp_replace(NEW.sku, '[^a-zA-Z0-9]', '', 'g'), '')), 'A') ||
          setweight(to_tsvector('english', coalesce(NEW.name, '')), 'B');
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER products_search_vector_trigger
        BEFORE INSERT OR UPDATE ON products
        FOR EACH ROW EXECUTE FUNCTION products_search_vector_update();
    SQL

    add_index :products, :search_vector, using: :gin
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS products_search_vector_trigger ON products;
      DROP FUNCTION IF EXISTS products_search_vector_update();
    SQL

    remove_index  :products, :search_vector
    remove_column :products, :search_vector

    add_column :products, :sku_normalized, :string
    add_index  :products, :sku_normalized
  end
end
