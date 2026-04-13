require "rails_helper"
require Rails.root.join("db/migrate/20260412050000_add_threat_variant_indexes_concurrently")

RSpec.describe AddThreatVariantIndexesConcurrently do
  let(:migration) { described_class.new }

  describe "migration safety" do
    it "disables DDL transaction for concurrent index creation" do
      expect(described_class.disable_ddl_transaction).to be true
    end
  end

  describe "#up" do
    it "is idempotent when indexes already exist" do
      conn = ActiveRecord::Base.connection
      expect(conn.index_exists?(
        :threat_variants, [ :probe_id, :prompt ],
        name: "index_threat_variants_on_probe_and_prompt"
      )).to be true

      expect(conn.index_exists?(
        :threat_variants, :prompt,
        name: "index_threat_variants_on_prompt"
      )).to be true

      expect { migration.up }.not_to raise_error
    end
  end

  describe "duplicate cleanup" do
    around do |example|
      conn = ActiveRecord::Base.connection
      conn.remove_index :threat_variants, name: "index_threat_variants_on_probe_and_prompt", if_exists: true
      example.run
    ensure
      unless conn.index_exists?(:threat_variants, [ :probe_id, :prompt ], name: "index_threat_variants_on_probe_and_prompt")
        conn.add_index :threat_variants, [ :probe_id, :prompt ], unique: true,
                       name: "index_threat_variants_on_probe_and_prompt"
      end
    end

    it "removes duplicate threat_variants keeping the newest" do
      probe = create(:probe)
      subindustry = create(:threat_variant_subindustry)
      conn = ActiveRecord::Base.connection
      now = Time.current.utc.iso8601

      conn.execute(<<~SQL)
        INSERT INTO threat_variants (probe_id, threat_variant_subindustry_id, prompt, created_at, updated_at)
        VALUES (#{probe.id}, #{subindustry.id}, 'dup_prompt', '#{(Time.current - 1.hour).utc.iso8601}', '#{now}')
      SQL

      conn.execute(<<~SQL)
        INSERT INTO threat_variants (probe_id, threat_variant_subindustry_id, prompt, created_at, updated_at)
        VALUES (#{probe.id}, #{subindustry.id}, 'dup_prompt', '#{now}', '#{now}')
      SQL

      newer_id = conn.execute("SELECT id FROM threat_variants WHERE probe_id = #{probe.id} AND prompt = 'dup_prompt' ORDER BY created_at DESC LIMIT 1").first["id"]

      expect(ThreatVariant.where(probe: probe, prompt: "dup_prompt").count).to eq(2)

      migration.send(:cleanup_duplicate_threat_variants)

      remaining = ThreatVariant.where(probe: probe, prompt: "dup_prompt")
      expect(remaining.count).to eq(1)
      expect(remaining.first.id).to eq(newer_id)
    end

    it "reassigns probe_results to the kept record before deleting duplicates" do
      probe = create(:probe)
      subindustry = create(:threat_variant_subindustry)
      conn = ActiveRecord::Base.connection
      now = Time.current.utc.iso8601

      conn.execute(<<~SQL)
        INSERT INTO threat_variants (probe_id, threat_variant_subindustry_id, prompt, created_at, updated_at)
        VALUES (#{probe.id}, #{subindustry.id}, 'fk_prompt', '#{(Time.current - 1.hour).utc.iso8601}', '#{now}')
      SQL

      conn.execute(<<~SQL)
        INSERT INTO threat_variants (probe_id, threat_variant_subindustry_id, prompt, created_at, updated_at)
        VALUES (#{probe.id}, #{subindustry.id}, 'fk_prompt', '#{now}', '#{now}')
      SQL

      older_id = conn.execute("SELECT id FROM threat_variants WHERE probe_id = #{probe.id} AND prompt = 'fk_prompt' ORDER BY created_at ASC LIMIT 1").first["id"]
      newer_id = conn.execute("SELECT id FROM threat_variants WHERE probe_id = #{probe.id} AND prompt = 'fk_prompt' ORDER BY created_at DESC LIMIT 1").first["id"]

      report = create(:report)
      pr = create(:probe_result, report: report, probe: probe, threat_variant_id: older_id)

      expect { migration.send(:cleanup_duplicate_threat_variants) }.not_to raise_error

      pr.reload
      expect(pr.threat_variant_id).to eq(newer_id)
      expect(ThreatVariant.where(probe: probe, prompt: "fk_prompt").count).to eq(1)
    end

    it "does not remove non-duplicate records" do
      probe = create(:probe)
      subindustry = create(:threat_variant_subindustry)

      v1 = create(:threat_variant, probe: probe, threat_variant_subindustry: subindustry, prompt: "prompt_a")
      v2 = create(:threat_variant, probe: probe, threat_variant_subindustry: subindustry, prompt: "prompt_b")

      migration.send(:cleanup_duplicate_threat_variants)

      expect(ThreatVariant.exists?(v1.id)).to be true
      expect(ThreatVariant.exists?(v2.id)).to be true
    end
  end
end
