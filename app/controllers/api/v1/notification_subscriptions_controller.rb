class Api::V1::NotificationSubscriptionsController < Api::BaseController
  def show
    render json: { public_key: VapidService.public_key }
  end

  def create
    subscription = NotificationSubscriptionBuilder.new(user: current_user, params: notification_subscription_params).perform
    render json: subscription
  end

  def destroy
    subscriptions = current_user.notification_subscriptions
    if params[:endpoint].present?
      subscriptions.browser_push.where("subscription_attributes->>'endpoint' = ?", params[:endpoint]).destroy_all
    elsif params[:push_token].present?
      subscriptions.fcm.where("subscription_attributes->>'push_token' = ?", params[:push_token]).destroy_all
    end
    head :ok
  end

  private

  def notification_subscription_params
    params.require(:notification_subscription).permit(
      :subscription_type, subscription_attributes: [:endpoint, :p256dh, :auth, :push_token, :device_id]
    )
  end
end
