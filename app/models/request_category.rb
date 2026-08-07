class RequestCategory < ApplicationRecord
  include TenantScoped

  # Slice 4's AI tool reads detail_fields to know which details it must
  # gather before it may propose a request in this category (e.g. ["date",
  # "time", "people"] for a reservation). Keep this list in sync with
  # whatever the AI tool's parameters actually support.
  ALLOWED_DETAIL_FIELDS = %w[quantity time date people description].freeze

  # Optional: a category is free to belong to no department.
  belongs_to :department, optional: true

  before_validation :compact_detail_fields

  validates :key, presence: true, uniqueness: { scope: :hotel_id }
  validates :name, presence: true
  validate :detail_fields_are_supported
  validate :department_must_belong_to_the_same_hotel

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :name) }

  private
    # A checkbox form for detail_fields submits a hidden blank fallback
    # alongside real values so an "uncheck everything" save still sends the
    # param at all (see app/views/staff/request_categories/_detail_fields_fields.html.erb) —
    # strip that blank (and any other blanks) before it can ever reach the
    # allowed-values validation below.
    def compact_detail_fields
      self.detail_fields = Array(detail_fields).reject(&:blank?)
    end

    def detail_fields_are_supported
      unsupported = Array(detail_fields) - ALLOWED_DETAIL_FIELDS
      return if unsupported.empty?

      errors.add(:detail_fields, "contains unsupported values: #{unsupported.join(', ')}")
    end

    # acts_as_tenant *can* auto-validate that a belongs_to target belongs to
    # the current tenant, but only for associations already declared at the
    # moment `acts_as_tenant` runs (it walks `reflect_on_all_associations`
    # once, from inside TenantScoped's `included do` block) — since `belongs_to
    # :department` is declared after `include TenantScoped` in this file, it
    # is invisible to that reflection and gets no automatic check. Rather
    # than depend on declaration order to get free security coverage, this
    # is explicit: `department` (the association reader) is itself
    # tenant-scoped, so it silently reads back nil for an id belonging to
    # another hotel — indistinguishable from a nonexistent id, which is
    # exactly the property we want (a hotel_admin tampering with a submitted
    # department_id learns nothing about whether that id exists elsewhere).
    def department_must_belong_to_the_same_hotel
      return if department_id.blank?

      errors.add(:department, "must belong to the same hotel") if department.nil?
    end
end
