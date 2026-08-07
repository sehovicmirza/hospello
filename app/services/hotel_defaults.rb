# Idempotently seeds a newly created hotel with a sensible starting set of
# departments and request categories, so assisted onboarding never starts
# from an empty screen. The hotel is free to rename, reorder, deactivate, or
# add to any of this afterward — these are starting values, not a fixed
# list, and the AI concierge (Slice 4) uses whatever the hotel ends up
# storing, including a name rewritten into Bosnian.
#
# Requires an ambient tenant matching `hotel` already set by the caller
# (Room/Department/RequestCategory are all tenant-scoped) — consistent with
# every other tenant-scoped write in this codebase, which is deliberately
# never made to work "by accident" without one. Call from inside
# `ActsAsTenant.with_tenant(hotel) { HotelDefaults.apply!(hotel) }`, as
# Platform::HotelsController#create does.
class HotelDefaults
  Category = Struct.new(:key, :name, :department, :detail_fields, keyword_init: true)

  DEPARTMENT_NAMES = [ "Reception", "Housekeeping", "Maintenance", "Food & Beverage" ].freeze

  CATEGORIES = [
    Category.new(key: "room_items", name: "Extra towels, bedding or toiletries",
      department: "Housekeeping", detail_fields: %w[quantity description]),
    Category.new(key: "cleaning", name: "Room cleaning",
      department: "Housekeeping", detail_fields: %w[time]),
    Category.new(key: "maintenance", name: "Report a problem",
      department: "Maintenance", detail_fields: %w[description]),
    Category.new(key: "wake_up_call", name: "Wake-up call",
      department: "Reception", detail_fields: %w[time]),
    Category.new(key: "dining_reservation", name: "Restaurant or breakfast reservation request",
      department: "Food & Beverage", detail_fields: %w[date time people]),
    Category.new(key: "spa_reservation", name: "Spa or wellness reservation request",
      department: "Reception", detail_fields: %w[date time people]),
    Category.new(key: "transport", name: "Taxi, airport transfer or luggage help",
      department: "Reception", detail_fields: %w[time description]),
    Category.new(key: "reception", name: "Something else for reception",
      department: "Reception", detail_fields: %w[description])
  ].freeze

  def self.apply!(hotel)
    new(hotel).apply!
  end

  def initialize(hotel)
    @hotel = hotel
  end

  def apply!
    departments_by_name = create_departments

    CATEGORIES.each_with_index do |category, index|
      hotel.request_categories.find_or_create_by!(key: category.key) do |record|
        record.name = category.name
        record.department = departments_by_name.fetch(category.department)
        record.detail_fields = category.detail_fields
        record.position = index
      end
    end
  end

  private
    attr_reader :hotel

    # find_or_create_by!'s block only runs on the create path, so re-running
    # apply! against a hotel that already has (possibly hotel-edited)
    # departments leaves their name/position alone rather than clobbering
    # them back to the English defaults.
    def create_departments
      DEPARTMENT_NAMES.each_with_index.to_h do |name, index|
        [ name, hotel.departments.find_or_create_by!(name: name) { |department| department.position = index } ]
      end
    end
end
