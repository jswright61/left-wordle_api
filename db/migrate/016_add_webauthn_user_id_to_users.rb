# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:users) do
      # base64url-encoded random WebAuthn user handle (set from Ruby via
      # WebAuthn.generate_user_id, see User#before_create). Deliberately
      # separate from the primary key -- this is what's sent to the
      # browser/authenticator as user.id, and the WebAuthn spec discourages
      # reusing an account identifier that could leak meaning (e.g.
      # sequential ids) as the user handle.
      add_column :webauthn_user_id, String, null: false
      add_index :webauthn_user_id, unique: true
    end
  end

  down do
    alter_table(:users) do
      drop_index :webauthn_user_id
      drop_column :webauthn_user_id
    end
  end
end
