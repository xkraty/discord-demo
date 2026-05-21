class BackfillSearchVectors < ActiveRecord::Migration[8.1]
  def up
    # Ensure trigger function is up to date (stripped SKU token added)
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
    SQL

    # Backfill all existing rows
    execute <<~SQL
      UPDATE products SET
        search_vector =
          setweight(to_tsvector('simple', coalesce(sku, '')), 'A') ||
          setweight(to_tsvector('simple', coalesce(regexp_replace(sku, '[^a-zA-Z0-9]', '', 'g'), '')), 'A') ||
          setweight(to_tsvector('english', coalesce(name, '')), 'B')
    SQL
  end

  def down; end
end
