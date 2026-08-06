class Hotel < ApplicationRecord
  SLUG_FORMAT = /\A[a-z0-9][a-z0-9-]*\z/
  COLOR_FORMAT = /\A#\h{6}\z/
  STAFF_LOCALES = %w[bs en].freeze

  enum :status, { active: 0, suspended: 1 }

  has_many :users, dependent: :destroy

  before_validation :normalize_slug

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: SLUG_FORMAT, message: "may only contain lowercase letters, numbers and hyphens" }
  validates :staff_locale, inclusion: { in: STAFF_LOCALES }
  validates :primary_color, :secondary_color,
    format: { with: COLOR_FORMAT, message: "must be a six-digit hex colour such as #1F3A5F" }
  validate :timezone_must_be_recognized

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
end
