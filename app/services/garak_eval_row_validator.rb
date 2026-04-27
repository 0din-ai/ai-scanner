class GarakEvalRowValidator
  Result = Struct.new(:valid, :errors, :passed, :total_evaluated, keyword_init: true) do
    def valid?
      valid
    end
  end

  class << self
    def call(row, require_probe_detector: false)
      errors = []

      unless row.is_a?(Hash)
        return Result.new(valid: false, errors: [ "row must be a JSON object" ])
      end

      errors << "entry_type must be eval" unless row["entry_type"] == "eval"

      passed = validate_count(row, "passed", errors)
      total_evaluated = validate_count(row, "total_evaluated", errors)

      if require_probe_detector
        validate_present_string(row, "probe", errors)
        validate_present_string(row, "detector", errors)
      end

      if passed && total_evaluated
        errors << "passed must be non-negative" if passed.negative?
        errors << "total_evaluated must be positive" if total_evaluated <= 0
        errors << "passed cannot exceed total_evaluated" if passed > total_evaluated
      end

      Result.new(
        valid: errors.empty?,
        errors: errors,
        passed: passed,
        total_evaluated: total_evaluated
      )
    end

    def valid?(row, require_probe_detector: false)
      call(row, require_probe_detector: require_probe_detector).valid?
    end

    private

    def validate_count(row, key, errors)
      value = row[key]
      unless value.is_a?(Integer)
        errors << "#{key} must be an integer"
        return nil
      end

      value
    end

    def validate_present_string(row, key, errors)
      value = row[key]
      return if value.is_a?(String) && value.present?

      errors << "#{key} must be a present string"
    end
  end
end
