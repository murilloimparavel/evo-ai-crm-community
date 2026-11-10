class Api::V1::NotificationSubscriptionsController < Api::BaseController
  before_action :set_user

  def show
    render json: { vapid_public_key: VapidService.public_key }
  end

  def create
    subscription = NotificationSubscriptionBuilder.new(user: @user, params: notification_subscription_params).perform
    render json: { id: subscription.id, subscription_type: subscription.subscription_type }
  end

  def destroy
    # Both browser and native clients may remove only their own subscription.
    subscriptions = @user.notification_subscriptions
    if params[:endpoint].present?
      subscriptions.browser_push.where(identifier: params[:endpoint]).destroy_all
    elsif params[:push_token].present?
      subscriptions.fcm.where("subscription_attributes->>'push_token' = ?", params[:push_token]).destroy_all
    end
    head :ok
  end

  private

  def set_user
    @user = current_user
  end

  def notification_subscription_params
    params.require(:notification_subscription).permit(:subscription_type, subscription_attributes: {})
  end
end
