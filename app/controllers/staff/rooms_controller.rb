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
        redirect_to staff_rooms_path, notice: "Room #{@room.number} added."
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
        numbers = Room.parse_bulk(params.dig(:bulk, :numbers))
      rescue Room::BulkRangeTooLarge => e
        return redirect_to staff_rooms_path, alert: e.message
      end

      created, skipped = bulk_add(numbers)
      redirect_to staff_rooms_path,
        notice: "#{created} room#{"s" unless created == 1} added, " \
                "#{skipped} skipped as duplicate#{"s" unless skipped == 1}."
    end

    def edit
    end

    def update
      if @room.update(room_params)
        redirect_to staff_rooms_path, notice: "Room #{@room.number} updated."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      if @room.destroy
        redirect_to staff_rooms_path, notice: "Room #{@room.number} deleted."
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
  end
end
