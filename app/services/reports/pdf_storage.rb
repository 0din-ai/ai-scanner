module Reports
  module PdfStorage
    # Canonicalize file_path and confirm it lives under storage/pdfs.
    # Follows symlinks so an attacker-planted link inside the sandbox cannot
    # redirect serving or deletion to files outside it. Tolerates a missing
    # basename so callers may validate paths before the file is written.
    # Returns the resolved absolute path on success, nil on any rejection.
    def self.safe_path(file_path)
      return nil if file_path.blank?
      return nil if file_path.include?("\u0000")

      sandbox_real = resolve_without_symlink_escape(File.expand_path(Rails.root.join("storage", "pdfs").to_s))
      resolved = resolve_without_symlink_escape(File.expand_path(file_path))

      if sandbox_real.nil? || resolved.nil? ||
         (resolved != sandbox_real && !resolved.start_with?(sandbox_real + File::SEPARATOR))
        Rails.logger.warn("Rejected PDF path outside sandbox: #{file_path}")
        return nil
      end

      resolved
    rescue ArgumentError, SystemCallError => e
      Rails.logger.warn("Invalid PDF path #{file_path.inspect}: #{e.message}")
      nil
    end

    # Resolve symlinks in every ancestor of the path. If the target path or one
    # of its parent directories does not exist yet, resolve the nearest existing
    # ancestor and then rebuild the trailing relative path. Reject broken
    # symlinks since their targets could later materialise as sandbox escapes.
    def self.resolve_without_symlink_escape(absolute)
      missing_components = []
      current = absolute

      loop do
        begin
          resolved = File.realpath(current)
          return missing_components.empty? ? resolved : File.join(resolved, *missing_components.reverse)
        rescue Errno::ENOENT
          return nil if File.symlink?(current)

          parent = File.dirname(current)
          basename = File.basename(current)
          return nil if basename.empty? || basename == "." || basename == ".." || parent == current

          missing_components << basename
          current = parent
        end
      end
    end
    private_class_method :resolve_without_symlink_escape
  end
end
