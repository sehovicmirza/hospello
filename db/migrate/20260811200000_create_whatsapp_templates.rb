class CreateWhatsappTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :whatsapp_templates do |t|
      # Cascades at the DB level, not a Ruby-level dependent: :destroy, for
      # the same ActsAsTenant::Errors::NoTenantSet reasoning documented on
      # Hotel's other has_many associations (WhatsappTemplate is
      # TenantScoped too). index: false — the composite unique index below
      # already leads with hotel_id, so a bare index here would be
      # redundant, the same reasoning messages.rb documents.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      # Meta's own template name — lowercase, digits and underscores only,
      # which is Meta's rule and not ours (see the model's validation). It
      # is the string #send_template passes as `name`, so a value that does
      # not match what was registered with Meta produces a send that fails
      # at the API rather than here.
      t.string :name, null: false

      # Meta's language code for this specific translation. A template is
      # identified by name AND language over there: "welcome" in bs and
      # "welcome" in de are two separately-approved objects, which is why
      # the unique index below covers both columns and not just the name.
      #
      # A plain string, not an enum constrained to
      # GuestLocaleHelper::SUPPORTED_LOCALES: Meta's own codes are its
      # vocabulary (pt_BR, zh_CN), a hotel may well approve a template in a
      # language this app's UI does not speak, and refusing to *record* one
      # would leave a hotel unable to explain why their send is failing.
      t.string :locale, null: false

      # utility: 0, marketing: 1, authentication: 2 — Meta's own three
      # categories, which decide both the pricing and the rules a template
      # is judged under. The welcome template this slice cares about is
      # `utility`, and the distinction is not cosmetic: a marketing
      # template sent to someone who did not opt in is what actually gets a
      # hotel's number restricted.
      t.integer :category, null: false, default: 0

      # pending: 0, approved: 1, rejected: 2 — a record of what META said,
      # never a decision this app makes. Only `approved` may be sent, and
      # Meta enforces that itself; this column exists so a hotel can see
      # whether their welcome message is usable yet without logging into
      # Meta's dashboard.
      t.integer :status, null: false, default: 0

      # The approved text, with Meta's own {{1}}-style placeholders left
      # verbatim. Stored for one reason: so a hotel can read what their own
      # template actually says. Nothing renders it — a template is sent by
      # name and Meta substitutes the components (see
      # Whatsapp::Provider#send_template), so this text never becomes a
      # message body in this app.
      t.text :body

      # Meta's stated reason when it rejects one. Free text and verbatim,
      # for the same reason whatsapp_channels.display_name_status is: it is
      # Meta's vocabulary, and a reason this app has never seen must still
      # be storable and readable rather than dropped.
      t.text :rejection_reason

      t.timestamps
    end

    # A template is identified by name + language at Meta, so that pair is
    # what must not repeat within a hotel. Scoped to hotel_id rather than
    # global — unlike whatsapp_channels.phone_number_id, this is not a
    # routing key: two hotels each having their own "welcome" template is
    # the ordinary case, not a collision.
    add_index :whatsapp_templates, %i[hotel_id name locale], unique: true
  end
end
