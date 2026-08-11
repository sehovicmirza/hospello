module Staff
  # Rooms are what the guest entry form (Slice 2) and the WhatsApp
  # set_guest_room tool (Slice 6) validate a typed room number against, via
  # Hotel#find_active_room — so a duplicate or a stray "1-99999" typo here is
  # not just a UI nuisance, it is bad guest-facing data. Everything below is
  # always scoped through Current.hotel — never a hotel id from params, per
  # this namespace's convention.
  class RoomsController < BaseController
    before_action :set_room, only: %i[edit update destroy]

    def index
      authorize Room
      @rooms = Current.hotel.rooms.ordered
      @room = Room.new
    end

    def create
      @room = Current.hotel.rooms.new(room_params)
      authorize @room

      if @room.save
        redirect_to staff_rooms_path, notice: t(".added", number: @room.number)
      else
        @rooms = Current.hotel.rooms.ordered
        render :index, status: :unprocessable_content
      end
    end

    # A separate action (not overloaded onto #create) because it accepts a
    # fundamentally different shape of input — a free-text blob, not room
    # attributes — and reports a summary rather than redirecting to a single
    # new record.
    def bulk_create
      authorize Room, :create?

      begin
        numbers = Room.parse_bulk(bulk_numbers_param)
      rescue Room::BulkRangeTooLarge => e
        # e.message is untranslated English — a defensive guard against a
        # pasted list absurd enough to create tens of thousands of rows
        # (Room::MAX_BULK_RANGE / MAX_BULK_TOTAL), not a routine confirmation
        # a receptionist sees in the course of ordinary work. Left as a
        # known, deliberate gap alongside Staff::ServiceRequestsController
        # #transition's own model-exception alert — see this task's report.
        return redirect_to staff_rooms_path, alert: e.message
      end

      created, skipped = bulk_add(numbers)
      redirect_to staff_rooms_path, notice: bulk_create_notice(created, skipped)
    end

    def edit
    end

    def update
      if @room.update(room_params)
        redirect_to staff_rooms_path, notice: t(".updated", number: @room.number)
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      if @room.destroy
        redirect_to staff_rooms_path, notice: t(".deleted", number: @room.number)
      else
        redirect_to staff_rooms_path, alert: @room.errors.full_messages.to_sentence
      end
    end

    private
      def set_room
        @room = Current.hotel.rooms.find(params[:id])
        authorize @room
      end

      def room_params
        params.require(:room).permit(:number, :active)
      end

      # `params[:bulk]` is ordinarily a nested hash (`bulk[numbers]=...`),
      # but a crafted request can post a bare scalar for it (`bulk=x`) —
      # `params.dig(:bulk, :numbers)` would then call `.dig` on that String,
      # which raises TypeError before Room.parse_bulk ever gets a chance to
      # handle bad input its own, safe way. Fall back to nil (which
      # Room.parse_bulk already treats as an empty list) for anything that
      # isn't the nested-params shape a real form submits.
      def bulk_numbers_param
        bulk = params[:bulk]
        bulk.is_a?(ActionController::Parameters) ? bulk[:numbers] : nil
      end

      # Each normalized number either creates a new room or is counted as a
      # duplicate — never raises on a collision, since a bulk paste
      # overlapping existing rooms is the expected case, not an error.
      def bulk_add(numbers)
        created = 0
        skipped = 0

        numbers.each do |number|
          room = Current.hotel.rooms.find_or_initialize_by(number: number)
          if room.persisted?
            skipped += 1
          else
            room.save!
            created += 1
          end
        end

        [ created, skipped ]
      end

      # Rails' own count-based pluralization (t(key, count:)), not string
      # surgery ("room#{"s" unless n == 1}") — that trick only ever produced
      # correct English, and Bosnian's plural forms don't follow English's
      # rule at all. Two independently-pluralized clauses can't share one
      # count, so each is its own key and this only wires them together.
      def bulk_create_notice(created, skipped)
        t(".summary",
          created_phrase: t(".created_phrase", count: created),
          skipped_phrase: t(".skipped_phrase", count: skipped))
      end
  end
end
