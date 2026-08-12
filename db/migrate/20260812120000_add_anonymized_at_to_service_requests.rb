class AddAnonymizedAtToServiceRequests < ActiveRecord::Migration[8.0]
  def change
    # When the guest's part of this request was cleared out of it — see
    # ServiceRequest.anonymize_all! for exactly which columns go.
    #
    # A marker rather than a derived predicate ("guest_session_id IS NULL"),
    # for three reasons, in order of how much they matter:
    #
    #   1. It makes the nightly purge incremental. Without it every run would
    #      rewrite every request inside the whole 365-day operational window,
    #      forever — a growing write every night that does nothing.
    #   2. It is itself a retention record: "this row's guest data was removed
    #      on 3 May" is the thing somebody needs when they ask whether an
    #      erasure really happened.
    #   3. A derived predicate would be wrong for a request that legitimately
    #      never had a guest session (nothing creates one today, but
    #      service_requests.guest_session_id is nullable and `source` already
    #      has a `staff` value waiting for it).
    #
    # No index: the scope that reads it always leads with created_at, and this
    # column is only ever an additional filter on rows that window has already
    # narrowed.
    add_column :service_requests, :anonymized_at, :datetime
  end
end
