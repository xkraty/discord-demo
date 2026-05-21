class OrdersController < ApplicationController
  before_action :authenticate_dashboard!

  def index
    @q = params[:q].to_s.strip
    @status = params[:status].to_s.strip.presence
    @orders = Order.includes(:product).order(ordered_at: :desc, id: :desc)
    @orders = @orders.where("orders.customer_email ILIKE :q OR products.name ILIKE :q OR products.sku ILIKE :q",
                            q: "%#{@q}%").references(:product) if @q.present?
    @orders = @orders.where(status: @status) if @status.present?
    @statuses = Order.distinct.pluck(:status).compact.sort
    @pagy, @orders = pagy(@orders, limit: 50)
  end
end
