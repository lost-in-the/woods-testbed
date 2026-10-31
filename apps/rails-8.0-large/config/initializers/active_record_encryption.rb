# Test-only keys so the testbed boots with no credentials file. Deterministic
# encryption keeps seeded ciphertext stable across fresh datasets. Never reuse
# these keys outside the testbed.
ActiveRecord::Encryption.configure(
  primary_key: ENV.fetch('CANOPY_ENCRYPTION_PRIMARY_KEY', 'canopy-testbed-primary-key-0123456789abcdef'),
  deterministic_key: ENV.fetch('CANOPY_ENCRYPTION_DETERMINISTIC_KEY', 'canopy-testbed-deterministic-key-0123456789'),
  key_derivation_salt: ENV.fetch('CANOPY_ENCRYPTION_SALT', 'canopy-testbed-key-derivation-salt-0123456789')
)
