module Platform
  # The platform admin's onboarding cockpit: create a hotel, see at a glance
  # whether it is live and whether it has a first admin yet, and suspend or
  # reactivate it. Branding (colors, logo, welcome message) is the hotel
  # admin's own job from the staff side (Task 3) — this controller only sets
  # identity and the platform-level switches listed in `hotel_params`.
  class HotelsController < BaseController
    before_action :set_hotel, only: %i[show edit update suspend activate plan]

    def index
      authorize Hotel
      @hotels = Hotel.order(created_at: :desc)

      # One grouped query for every hotel's staff count and one for which
      # hotels already have a first admin, instead of N+1 queries per row.
      # `.staff` excludes the hotel_admin row itself — a freshly onboarded
      # hotel with only its admin reads "Staff 0", not a misleading "Staff 1".
      # `.active` on the admin check matters too: a hotel whose only admin was
      # deactivated must read "Not yet", not a stale "Yes".
      @staff_counts = User.staff.where(hotel_id: @hotels.map(&:id)).group(:hotel_id).count
      @hotel_ids_with_admin = User.hotel_admin.active.where(hotel_id: @hotels.map(&:id)).distinct.pluck(:hotel_id).to_set

      # Unlike @staff_counts above, this cannot be one grouped cross-hotel
      # query: Room is tenant-scoped (unlike User), so
      # Room.where(hotel_id: ids).group(:hotel_id).count would raise
      # ActsAsTenant::Errors::NoTenantSet under require_tenant = true — see
      # Task 4's brief. Each hotel's count is wrapped in its own with_tenant
      # instead; the resulting N+1 is fine at pilot scale (a handful of hotels).
      @room_counts = @hotels.to_h { |hotel| [ hotel.id, ActsAsTenant.with_tenant(hotel) { hotel.rooms.count } ] }
    end

    def new
      # Essentials, because that is the plan being sold — not the column
      # default, which is `service` for an unrelated reason (see the migration:
      # it means "the app as built" so that existing tests and existing hotels
      # keep the product they were written against). The two defaults answer
      # two different questions and this is the one a human sees.
      @hotel = Hotel.new(plan: :essentials)
      authorize @hotel
    end

    def create
      # plan is permitted here and nowhere else: a hotel has to be born with
      # one, and every later change goes through #plan so it lands in the audit
      # log under its own action.
      @hotel = Hotel.new(hotel_params.merge(plan: params[:hotel][:plan].presence || :essentials))
      authorize @hotel

      # save, seed-the-defaults, and audit-log as one all-or-nothing unit:
      # without the transaction, a failure inside HotelDefaults.apply! or
      # audit! (a bug, a rare find_or_create_by! race) would leave a
      # persisted hotel with partial or no defaults and no audit row behind
      # it — an orphan an operator would have to notice and fix by hand.
      # Any exception here rolls back the hotel insert too and propagates
      # (deliberately not rescued): a broken seed is a bug worth a loud
      # failure, not a hotel silently created without one.
      created = Hotel.transaction do
        next false unless @hotel.save

        # Room/Department/RequestCategory are all tenant-scoped, so seeding
        # them requires an explicit tenant here — there is no ambient one in
        # this platform-namespace request (Platform::BaseController sets
        # none on purpose).
        ActsAsTenant.with_tenant(@hotel) { HotelDefaults.apply!(@hotel) }
        audit!("hotel.create", target: @hotel, hotel: @hotel)
        true
      end

      if created
        redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} created."
      else
        render :new, status: :unprocessable_content
      end
    end

    def show
      @admins = @hotel.users.hotel_admin.order(:name)
      @staff_count = @hotel.users.staff.count
    end

    def edit
    end

    def update
      if @hotel.update(hotel_params)
        audit!("hotel.update", target: @hotel, hotel: @hotel)
        redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} updated."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def suspend
      if @hotel.suspended?
        redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} is already suspended."
      elsif @hotel.update(status: :suspended)
        audit!("hotel.suspend", target: @hotel, hotel: @hotel)
        redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} suspended."
      else
        redirect_to platform_hotel_path(@hotel),
          alert: "#{@hotel.name} could not be suspended: #{@hotel.errors.full_messages.to_sentence}"
      end
    end

    # Which plan a hotel is on, and how many rooms it may have — changed
    # together, through their own action, and never through #update.
    #
    # This follows the precedent `status` set (see hotel_params): a commercially
    # significant change gets its own named audit action, so "what moved this
    # hotel onto Essentials, and when" is never something you have to infer from
    # a generic hotel.update row. The from/to go into audit!'s metadata bag,
    # which every existing call site leaves empty and which exists for exactly
    # this.
    #
    # room_limit is edited here rather than on the shared form because it is
    # meaningless without the plan beside it: an empty box means "whatever
    # Essentials includes", and that sentence needs the plan on screen to parse.
    def plan
      was = @hotel.plan
      limit = params[:hotel][:room_limit].presence

      if @hotel.update(plan: params[:hotel][:plan], room_limit: limit)
        audit!("hotel.plan_change", target: @hotel, hotel: @hotel, from: was, to: @hotel.plan,
               room_limit: @hotel.room_limit)
        redirect_to platform_hotel_path(@hotel), notice: plan_change_notice(was)
      else
        redirect_to platform_hotel_path(@hotel),
          alert: "#{@hotel.name}'s plan could not be changed: #{@hotel.errors.full_messages.to_sentence}"
      end
    end

    def activate
      if @hotel.active?
        redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} is already active."
      elsif @hotel.update(status: :active)
        audit!("hotel.activate", target: @hotel, hotel: @hotel)
        redirect_to platform_hotel_path(@hotel), notice: "#{@hotel.name} reactivated."
      else
        redirect_to platform_hotel_path(@hotel),
          alert: "#{@hotel.name} could not be reactivated: #{@hotel.errors.full_messages.to_sentence}"
      end
    end

    private
      def set_hotel
        @hotel = Hotel.find(params[:id])
        authorize @hotel
      end

      # status is deliberately absent: it changes only through #suspend and
      # #activate, each writing its own named audit action, so "what changed
      # the hotel's live/suspended state" is never ambiguous in the log.
      # Says what actually happened rather than "Saved": a plan change and a
      # room-limit change are two different commercial facts and an operator
      # needs to see which one they just made.
      def plan_change_notice(was)
        ceiling = @hotel.effective_room_limit
        rooms = ceiling.nil? ? "no room limit" : "up to #{ceiling} rooms"

        if was == @hotel.plan
          "#{@hotel.name} stays on #{@hotel.plan.capitalize} — #{rooms}."
        else
          "#{@hotel.name} moved from #{was.capitalize} to #{@hotel.plan.capitalize} — #{rooms}."
        end
      end

      # status is deliberately absent, and so is plan: each changes only through
      # its own named action (#suspend / #activate, #plan), so "what changed this
      # hotel's live state, or what it pays for" is never ambiguous in the log.
      def hotel_params
        params.require(:hotel).permit(
          :name, :slug, :timezone, :staff_locale,
          :powered_by_visible, :ai_enabled, :ai_daily_token_budget,
          :escalation_email
        )
      end
  end
end
