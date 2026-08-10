# A request the guest and the assistant are still working out.
#
# **Why a table and not a flag.** "Can I get two extra towels around 6pm" often
# arrives in pieces — "two towels", then "when?", then "6pm". Something has to
# hold the partial request across those turns, expire it if the guest wanders
# off, and make it impossible for a retried tool call to produce a second
# request. A row with a state does all three. A boolean on the conversation
# does none of them.
class CreateServiceRequestDrafts < ActiveRecord::Migration[8.0]
  def change
    create_table :service_request_drafts do |t|
      # Same cascade reasoning as rooms — see create_rooms.rb.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      # Cascade here, unlike service_requests: an unconfirmed draft has no
      # life of its own outside the conversation that is negotiating it.
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }, index: false

      # Unknown until the guest says what they want, so nullable — the first
      # turn may be nothing more than "I need something".
      t.references :request_category, foreign_key: { on_delete: :nullify }

      t.jsonb :details, null: false, default: {}

      # gathering: 0, awaiting_confirmation: 1, confirmed: 2, discarded: 3,
      # expired: 4.
      t.integer :status, null: false, default: 0

      # A guest who abandons a half-finished request mid-conversation must not
      # have it spring to life an hour later — see ExpireDraftsJob.
      t.datetime :expires_at, null: false

      t.timestamps
    end

    # The guarantee, made by Postgres rather than by application care: one
    # live draft per conversation. Without it, a guest sending two messages
    # quickly can start a second negotiation while the first is still open,
    # and end up confirming one request while reading the summary of another.
    add_index :service_request_drafts, :conversation_id, unique: true,
      where: "status IN (0, 1)", name: "index_one_live_draft_per_conversation"

    # ExpireDraftsJob's own read: live drafts past their expiry.
    add_index :service_request_drafts, [ :status, :expires_at ]
  end
end
