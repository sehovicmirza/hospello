module Whatsapp
  # A signature-verified delivery that named a phone_number_id no hotel in
  # this app owns.
  #
  # **Reported, never raised.** Meta retries anything that is not a 200, and
  # the webhook endpoint answered 200 the moment it stored the delivery — so
  # raising here would neither reach Meta nor help anyone; it would only fill
  # the failed-jobs table with a message that will never route however many
  # times it is retried. Whatsapp::InboundRouter marks the WebhookEvent
  # `ignored` and hands one of these to Sentry, which needs an exception
  # object to attach a stack trace to.
  #
  # It is not noise: in production it means either a hotel was offboarded
  # while Meta still had the subscription, or somebody's phone_number_id was
  # entered wrong — both of which are silent guest-message loss until a
  # person looks.
  class UnroutableDelivery < Error; end
end
