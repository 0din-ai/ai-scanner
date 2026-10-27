module Users
  # Admin form saves must keep the active company and the membership join rows
  # together. Assigning company_ids on a persisted record otherwise writes eagerly.
  class SaveWithCompanyAccess
    attr_reader :selected_company_ids, :current_company_id

    def initialize(user, attributes, default_company: nil)
      @user = user
      @attributes = attributes.to_h.symbolize_keys
      @default_company = default_company
      @access_errors = []
    end

    def call
      saved = false
      @user.with_lock do
        change_access = @user.new_record? || @attributes.key?(:company_ids) || @attributes.key?(:current_company_id)
        @user.assign_attributes(@attributes.except(:company_ids, :current_company_id))
        if change_access
          prepare_access
        else
          @selected_company_ids = @user.company_ids
          @current_company_id = @user.current_company_id
        end

        @user.valid?
        @access_errors.each { |field, message| @user.errors.add(field, message) }
        raise ActiveRecord::Rollback if @user.errors.any?

        @user.save!
        @user.company_ids = selected_company_ids if change_access
        saved = true
      end
      saved
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved,
      ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotFound
      @user.errors.add(:base, "User could not be saved. Please retry.") if @user.errors.empty?
      false
    end

    private

    def prepare_access
      explicit_memberships = @attributes.key?(:company_ids)
      @selected_company_ids = if explicit_memberships
        Array(@attributes[:company_ids]).reject(&:blank?).filter_map { |id| parse_id(id, :companies) }.uniq
      else
        @user.company_ids.dup
      end

      @current_company_id = if @attributes.key?(:current_company_id)
        parse_id(@attributes[:current_company_id], :current_company)
      elsif @user.new_record?
        explicit_memberships ? selected_company_ids.first : @default_company&.id
      else
        @user.current_company_id
      end

      # Legacy active-company-only updates add that membership without removing
      # other intentional memberships. Explicit selections are authoritative.
      @selected_company_ids |= [ current_company_id ].compact unless explicit_memberships

      @access_errors << [ :companies, "must include at least one company" ] if selected_company_ids.empty?
      @access_errors << [ :current_company, "must be selected" ] unless current_company_id
      if current_company_id && !selected_company_ids.include?(current_company_id)
        @access_errors << [ :current_company, "must be one of the member companies" ]
      end

      requested_ids = (selected_company_ids + [ current_company_id ]).compact.uniq
      companies = Company.where(id: requested_ids).index_by(&:id)
      if (selected_company_ids - companies.keys).any?
        @access_errors << [ :companies, "include a company that no longer exists" ]
      end
      if current_company_id && !companies.key?(current_company_id)
        @access_errors << [ :current_company, "does not exist" ]
      end
      @user.current_company = companies[current_company_id]
    end

    def parse_id(value, field)
      return if value.blank?
      text = value.to_s
      if text.match?(/\A[1-9]\d{0,18}\z/) && text.to_i <= 9_223_372_036_854_775_807
        text.to_i
      else
        @access_errors << [ field, "contains an invalid company ID" ]
        nil
      end
    end
  end
end
