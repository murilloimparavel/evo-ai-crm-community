class Api::V1::NotificationSubscriptionsController < Api::BaseController
  def show
    render json: { public_key: VapidService.public_key }
  end

  def create
    subscription = NotificationSubscriptionBuilder.new(user: current_user, params: notification_subscription_params).perform
    render json: subscription
  end

  def test
    return head :unauthorized unless current_user

    subscription = current_user.notification_subscriptions.browser_push.find_by!(identifier: params.require(:endpoint))
    unless Notification::TestPushNotificationJob.supported_endpoint?(subscription.identifier)
      return render json: { error: 'Este serviço de push não é compatível com o teste.' }, status: :unprocessable_entity
    end

    unless Rails.cache.write("web-push-test:#{current_user.id}", true, expires_in: 30.seconds, unless_exist: true)
      return render json: { error: 'Aguarde 30 segundos antes de enviar outro teste.' }, status: :too_many_requests
    end

    Notification::TestPushNotificationJob.set(wait: 10.seconds).perform_later(subscription.id, current_user.id)
    render json: { delay_seconds: 10 }, status: :accepted
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
