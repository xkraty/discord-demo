class OrdersController < ApplicationController
  before_action :authenticate_dashboard!

  def index
    @q = params[:q].to_s.strip
    @orders = Order.includes(:product).order(ordered_at: :desc, id: :desc)
    @orders = @orders.where("products.name ILIKE :q OR products.sku ILIKE :q",
                            q: "%#{@q}%").references(:product) if @q.present?
    @pagy, @orders = pagy(@orders, limit: 50)
  end
end
