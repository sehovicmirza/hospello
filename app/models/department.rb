class Department < ApplicationRecord
  include TenantScoped

  # Deactivating is the default action the UI offers; deletion is only ever
  # allowed when nothing references the record. request_categories.department_id
  # is nullable at the DB level (on_delete: :nullify — see
  # db/migrate/*_create_request_categories.rb) as a defense-in-depth net for
  # paths that bypass Rails entirely, but the normal `Department#destroy`
  # call goes through this and refuses outright while categories still
  # point here, rather than silently orphaning them.
  has_many :request_categories, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: { scope: :hotel_id }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :name) }
end
