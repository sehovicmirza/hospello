class Hotel < ApplicationRecord
  SLUG_FORMAT = /\A[a-z0-9][a-z0-9-]*\z/
  COLOR_FORMAT = /\A#\h{6}\z/
  STAFF_LOCALES = %w[bs en].freeze

  LOGO_CONTENT_TYPES = %w[image/png image/jpeg image/webp image/svg+xml].freeze
  LOGO_MAX_SIZE = 2.megabytes

  # No SVG here (unlike the logo): this is a photographic hero image for the
  # guest landing page, not a vector mark, so there is no legitimate use for
  # it and one fewer reason to worry about an SVG's embedded-script risk.
  WELCOME_IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  WELCOME_IMAGE_MAX_SIZE = 5.megabytes

  enum :status, { active: 0, suspended: 1 }

  has_many :users, dependent: :destroy

  # Deliberately no `dependent:` here (unlike `users` above): Room,
  # Department and RequestCategory are all tenant-scoped (TenantScoped /
  # acts_as_tenant), so a Ruby-level cascade (`dependent: :destroy` or
  # `:delete_all`) would run those models' queries outside any
  # ActsAsTenant.with_tenant block during a bare `hotel.destroy` and raise
  # ActsAsTenant::Errors::NoTenantSet under require_tenant = true. The
  # hotel_id foreign keys on all three tables cascade at the database level
  # instead (see db/migrate/*_create_rooms.rb and friends), so Postgres
  # removes the dependent rows without Rails ever having to query them.
  has_many :rooms
  has_many :departments
  has_many :request_categories
  has_many :guest_sessions
  has_many :conversations
  has_many :messages
  has_many :kb_entries
  has_many :ai_runs
  has_many :ai_usage_days
  has_many :unanswered_questions
  has_many :service_requests
  has_many :service_request_drafts
  has_one :whatsapp_channel
  has_many :whatsapp_templates

  has_one_attached :logo
  has_one_attached :welcome_image

  before_validation :normalize_slug

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: SLUG_FORMAT, message: "may only contain lowercase letters, numbers and hyphens" }
  validates :staff_locale, inclusion: { in: STAFF_LOCALES }
  validates :primary_color, :secondary_color,
    format: { with: COLOR_FORMAT, message: "must be a six-digit hex colour such as #1F3A5F" }
  validate :timezone_must_be_recognized
  validate :logo_must_be_a_supported_type_and_size
  validate :welcome_image_must_be_a_supported_type_and_size

  # The single lookup Slice 2's guest entry form and Slice 6's WhatsApp
  # set_guest_room tool call both use: normalizes the input the same way
  # Room itself normalizes `number` on save (strip, upcase, collapse
  # whitespace — see Room.normalize_number), so a guest typing " ph1 " finds
  # a room saved as "PH1". Inactive rooms never match, so a decommissioned
  # room number quietly refuses a guest instead of seating them nowhere.
  def find_active_room(number)
    rooms.active.find_by(number: Room.normalize_number(number))
  end

  # Everything the Slice 3 concierge is allowed to know about this hotel,
  # and nothing else. Named here rather than left as a chain at each call
  # site so there is exactly one answer to "which entries may the model
  # see" — a draft slipping into a prompt is not a bug anyone would notice
  # from the outside until a guest quoted it back.
  def published_kb_entries
    kb_entries.published.ordered
  end

  private
    # A blank slug is derived from the name; a supplied slug is tidied into the
    # same shape so the URL a guest scans is always predictable.
    def normalize_slug
      self.slug = if slug.blank?
        name.to_s.parameterize
      else
        slug.strip.downcase.gsub(/\s+/, "-")
      end
    end

    def timezone_must_be_recognized
      return if ActiveSupport::TimeZone::MAPPING.value?(timezone)

      ActiveSupport::TimeZone.find_tzinfo(timezone.to_s)
    rescue TZInfo::InvalidTimezoneIdentifier
      errors.add(:timezone, "is not a recognized time zone")
    end

    # Plain custom validation — no validation gem. content_type and byte_size
    # are set synchronously at attach time, so this needs no analyzer/variant
    # round trip.
    def logo_must_be_a_supported_type_and_size
      return unless logo.attached?

      errors.add(:logo, "must be a PNG, JPEG, WebP or SVG image") unless logo.content_type.in?(LOGO_CONTENT_TYPES)
      errors.add(:logo, "must be smaller than 2 MB") if logo.blob.byte_size > LOGO_MAX_SIZE
    end

    def welcome_image_must_be_a_supported_type_and_size
      return unless welcome_image.attached?

      unless welcome_image.content_type.in?(WELCOME_IMAGE_CONTENT_TYPES)
        errors.add(:welcome_image, "must be a PNG, JPEG or WebP image")
      end
      errors.add(:welcome_image, "must be smaller than 5 MB") if welcome_image.blob.byte_size > WELCOME_IMAGE_MAX_SIZE
    end
end
