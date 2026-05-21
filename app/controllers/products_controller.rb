class ProductsController < ApplicationController
  before_action :authenticate_dashboard!

  def index
    @q = params[:q].to_s.strip
    @products = Product.order(:name)
    @products = @products.where("name ILIKE :q OR sku ILIKE :q", q: "%#{@q}%") if @q.present?
    @pagy, @products = pagy(@products, limit: 50)
  end

  def show
    @product = Product.find(params[:id])
    @orders  = @product.orders.order(ordered_at: :desc)
  end
end
