# Internal notes (Slice 2 Task 3's reception inbox) live in the same
# messages table as guest-visible replies rather than a table of their own,
# because what a receptionist needs from the conversation detail view is one
# chronological story — "guest asked, I noted the room was already serviced,
# I replied" reads wrong if half of it is in a sidebar.
#
# The cost of that choice is that one wrong query leaks staff commentary to
# a guest, so the default is the safe one: every existing row, and every row
# written by any code that doesn't say otherwise, is guest_visible. Making
# something invisible to the guest is the deliberate act, never the omission.
class AddVisibilityToMessages < ActiveRecord::Migration[8.0]
  def change
    # guest_visible: 0, internal: 1
    add_column :messages, :visibility, :integer, null: false, default: 0

    # Every guest-facing read filters on this (Message.guest_visible — see
    # Guest::ChatsController, Guest::MessagesController#index, and
    # Conversation#broadcast_new_message), and each of those reads is
    # already ordered by [conversation_id, id]. Extending that same index
    # with visibility keeps the guest transcript a single index scan
    # instead of a filter over every message in the conversation.
    add_index :messages, [ :conversation_id, :visibility, :id ]
  end
end
