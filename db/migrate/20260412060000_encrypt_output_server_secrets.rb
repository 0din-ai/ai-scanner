# frozen_string_literal: true

# Encrypts sensitive credential fields on OutputServer at rest using
# Rails ActiveRecord Encryption with per-tenant key isolation.
#
# Phase 1: Changes column types from string to text (encrypted payloads
#           are opaque strings that may exceed varchar limits).
# Phase 2: Encrypts existing plaintext records with per-tenant derived keys.
class EncryptOutputServerSecrets < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    change_column :output_servers, :access_token, :text
    change_column :output_servers, :api_key, :text
    change_column :output_servers, :password, :text

    say_with_time "Encrypting output server secrets with per-tenant keys" do
      count = 0
      failures = []
      ActsAsTenant.without_tenant do
        OutputServer.in_batches(of: 100) do |batch|
          batch.each do |server|
            ActsAsTenant.with_tenant(server.company) do
              if server.access_token.present? || server.api_key.present? || server.password.present?
                server.encrypt
                count += 1
              end
            end
          rescue StandardError => e
            failures << { id: server.id, error: e.message }
            say "Failed to encrypt output server #{server.id}: #{e.message}"
          end
        end
      end
      raise "Failed to encrypt #{failures.size} output server(s): #{failures.inspect}" if failures.any?
      count
    end
  end

  def down
    unless OutputServer.encrypted_attributes&.include?(:access_token)
      raise "Cannot rollback: OutputServer model must still have 'encrypts' declarations. " \
            "Restore model code first, then rollback migration."
    end

    ActsAsTenant.without_tenant do
      say_with_time "Decrypting output server secrets" do
        count = 0
        failures = []
        OutputServer.find_each do |server|
          updates = {}
          ActsAsTenant.with_tenant(server.company) do
            updates[:access_token] = server.access_token if server.access_token.present?
            updates[:api_key] = server.api_key if server.api_key.present?
            updates[:password] = server.password if server.password.present?
          end
          if updates.any?
            OutputServer.where(id: server.id).update_all(updates)
            count += 1
          end
        rescue StandardError => e
          failures << { id: server.id, error: e.message }
          say "Failed to decrypt output server #{server.id}: #{e.message}"
        end
        raise "Failed to decrypt #{failures.size} output server(s): #{failures.inspect}" if failures.any?
        count
      end
    end

    change_column :output_servers, :access_token, :string
    change_column :output_servers, :api_key, :string
    change_column :output_servers, :password, :string
  end
end
