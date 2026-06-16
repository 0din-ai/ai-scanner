module Stats
  class LastFiveScansData
    def call
      Scan.order(created_at: :desc)
          .limit(5)
          .map do |scan|
            {
              scan_name: scan.name,
              scan_id: scan.id,
              asr: (scan.avg_successful_attacks || 0).round
            }
          end
    end
  end
end
