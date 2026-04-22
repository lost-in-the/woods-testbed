# frozen_string_literal: true

# Seed Credential rows using ONLY officially documented test/example
# credentials. No real keys, no plausible-looking inventions.
#
# Each row is shaped to look the way these credentials actually appear in
# Rails apps: persisted in a model column, sometimes inside a JSON blob,
# sometimes referenced inside notes. The Console MCP harness reads this data
# back out through every Tier 1 read tool to verify the credential scanner
# (Layer 2) and column redaction (Layer 3) work end-to-end.

Credential.delete_all

CREDENTIAL_FIXTURES = [
  # ── Covered by CredentialScanner patterns ────────────────────────────
  { provider: 'stripe',     key_type: 'secret_key',       value: 'sk_test_4eC39HqLyjWDarjtT1zdp7dc',
    notes: 'Stripe public test key from their docs',                      detected: true,  pattern: :stripe_secret_key },
  { provider: 'stripe',     key_type: 'restricted_key',   value: 'rk_test_BQokikJOvBiI2HlWgH4olfQ2',
    notes: 'Stripe restricted-test format example',                       detected: true,  pattern: :stripe_secret_key },
  { provider: 'stripe',     key_type: 'publishable_key',  value: 'pk_test_TYooMQauvdEDq54NiTphI7jx',
    notes: 'Stripe publishable test key from their docs',                 detected: true,  pattern: :stripe_publishable_key },
  { provider: 'stripe',     key_type: 'webhook_secret',   value: "whsec_#{'A1b2C3d4E5f6G7h8I9j0K1l2'}",
    notes: 'Stripe whsec example (alphanumeric body, length-bounded)',    detected: true,  pattern: :stripe_webhook_secret },

  { provider: 'aws',        key_type: 'access_key_id',    value: 'AKIAIOSFODNN7EXAMPLE',
    notes: 'Canonical AWS docs example access key',                       detected: true,  pattern: :aws_access_key_id },
  { provider: 'aws',        key_type: 'session_key_id',   value: 'ASIAIOSFODNN7EXAMPLE',
    notes: 'AWS STS session token access key example',                    detected: true,  pattern: :aws_access_key_id },

  { provider: 'github',     key_type: 'classic_pat',      value: 'ghp_16C7e42F292c6912E7710c838347Ae178B4a',
    notes: 'GitHub classic PAT example shape',                            detected: true,  pattern: :github_token },
  { provider: 'github',     key_type: 'fine_grained_pat', value: "github_pat_#{'A' * 82}",
    notes: 'GitHub fine-grained PAT length example (filler)',             detected: true,  pattern: :github_fine_grained_pat },

  { provider: 'google',     key_type: 'oauth_access',     value: 'ya29.A0ARrdaM-EXAMPLE_TOKEN_VALUE_FILLER_xyz',
    notes: 'Google OAuth ya29 token shape',                               detected: true,  pattern: :google_oauth_token },

  { provider: 'jwt',        key_type: 'signed_token',
    value: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c',
    notes: 'jwt.io textbook example token',                               detected: true,  pattern: :jwt_token },

  { provider: 'pem',        key_type: 'rsa_block',
    value: "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0Z3VS5JJcds3xfNn\nFAKEKEYBLOCKFAKEKEYBLOCKFAKE\n-----END RSA PRIVATE KEY-----",
    notes: 'PEM-armored block (filler body)',                             detected: true,  pattern: :pem_private_key_block },

  { provider: 'slack',      key_type: 'bot_token',        value: 'xoxb-1234567890-abcdefghij',
    notes: 'Slack bot token example shape',                               detected: true,  pattern: :slack_token },

  { provider: 'sendgrid',   key_type: 'api_key',          value: "SG.#{'a' * 22}.#{'b' * 43}",
    notes: 'SendGrid API key length example (filler)',                    detected: true,  pattern: :sendgrid_api_key },

  { provider: 'mailgun',    key_type: 'api_key',          value: 'key-1234567890abcdef1234567890abcdef',
    notes: 'Mailgun legacy API key shape (key- + 32 hex)',                detected: true,  pattern: :mailgun_api_key },

  { provider: 'anthropic',  key_type: 'api_key',          value: "sk-ant-api03-#{'A' * 80}",
    notes: 'Anthropic API key length example (filler)',                   detected: true,  pattern: :anthropic_api_key },

  { provider: 'openai',     key_type: 'project_key',      value: "sk-proj-#{'A' * 40}",
    notes: 'OpenAI project key length example (filler)',                  detected: true,  pattern: :openai_api_key },

  { provider: 'shopify',    key_type: 'access_token',     value: "shpat_#{'a' * 32}",
    notes: 'Shopify access token length example (filler)',                detected: true,  pattern: :shopify_access_token },

  { provider: 'square',     key_type: 'access_token',     value: "sq0atb-#{'A' * 22}",
    notes: 'Square access token shape example',                           detected: true,  pattern: :square_access_token },

  { provider: 'paypal',     key_type: 'access_token',     value: 'access_token$sandbox$abcd1234efgh$0123456789abcdef',
    notes: 'PayPal sandbox access token shape',                           detected: true,  pattern: :paypal_access_token },

  # ── NOT covered by current scanner — these prove gap detection ───────
  { provider: 'shippo',     key_type: 'api_key',          value: 'shippo_test_abcdef0123456789abcdef0123456789ab',
    notes: 'Shippo test key prefix from their docs',                      detected: false, pattern: nil },
  { provider: 'postmark',   key_type: 'server_token',     value: 'POSTMARK_API_TEST',
    notes: 'Postmark literal sandbox token from their docs',              detected: false, pattern: nil },
  { provider: 'postmark',   key_type: 'uuid_token',       value: '01234567-89ab-cdef-0123-456789abcdef',
    notes: 'Postmark UUID-shaped server token',                           detected: false, pattern: nil },
  { provider: 'appsignal',  key_type: 'push_api_key',     value: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    notes: 'Appsignal push key UUID shape',                               detected: false, pattern: nil },

  # ── Additional documented test keys (uncovered — expand gap report) ─
  { provider: 'gitlab',     key_type: 'pat',              value: 'glpat-xxxxxxxxxxxxxxxxxxxx',
    notes: 'GitLab PAT prefix shape (glpat- + 20 chars), per GitLab docs', detected: false, pattern: nil },
  { provider: 'digitalocean', key_type: 'oauth_token',    value: "dop_v1_#{'0' * 64}",
    notes: 'DigitalOcean OAuth token prefix shape (dop_v1_ + 64 hex)',    detected: false, pattern: nil },
  { provider: 'notion',     key_type: 'integration',      value: "secret_#{'A' * 43}",
    notes: 'Notion internal integration token shape',                     detected: false, pattern: nil },
  { provider: 'npm',        key_type: 'access_token',     value: "npm_#{'a' * 36}",
    notes: 'npm access token (npm_ + 36 chars), per npm RFC',             detected: false, pattern: nil },
  { provider: 'datadog',    key_type: 'api_key',          value: "DATADOG_TESTKEY_#{'X' * 16}",
    notes: 'Datadog-shaped fixture (obviously fake to avoid secret scanners)', detected: false, pattern: nil },
  { provider: 'heroku',     key_type: 'api_key',          value: 'HEROKU-TESTKEY-0000-0000-000000000000',
    notes: 'Heroku-shaped fixture (obviously fake to avoid secret scanners)', detected: false, pattern: nil },
  { provider: 'sentry',     key_type: 'auth_token',       value: "sntrys_TESTKEY_#{'X' * 32}",
    notes: 'Sentry-shaped fixture (obviously fake to avoid secret scanners)', detected: false, pattern: nil },
  { provider: 'cloudflare', key_type: 'api_token',        value: "v1.0-TESTKEY_#{'X' * 28}",
    notes: 'Cloudflare-shaped fixture (obviously fake to avoid secret scanners)', detected: false, pattern: nil },
  { provider: 'twilio',     key_type: 'account_sid',      value: "ACTESTKEY#{'X' * 24}",
    notes: 'Twilio SID-shaped fixture (obviously fake to avoid secret scanners)', detected: false, pattern: nil },
  { provider: 'twilio',     key_type: 'auth_token',       value: 'TWILIO_TESTKEY_your_auth_token_here',
    notes: 'Twilio auth token-shaped fixture (obviously fake)',           detected: false, pattern: nil },
  { provider: 'resend',     key_type: 'api_key',          value: "re_TESTKEY_#{'X' * 32}",
    notes: 'Resend-shaped fixture (obviously fake to avoid secret scanners)', detected: false, pattern: nil },
  { provider: 'linear',     key_type: 'api_key',          value: "lin_api_TESTKEY_#{'X' * 32}",
    notes: 'Linear-shaped fixture (obviously fake to avoid secret scanners)', detected: false, pattern: nil },
  { provider: 'discord',    key_type: 'bot_token',        value: "DISCORD_TESTKEY_#{'X' * 24}.TEST.#{'Y' * 27}",
    notes: 'Discord-shaped fixture (obviously fake to avoid secret scanners)', detected: false, pattern: nil },
  { provider: 'mailchimp',  key_type: 'api_key',          value: "TESTKEY#{'X' * 25}-us21",
    notes: 'Mailchimp-shaped api key (32 + -dcN). Literal kept obviously-fake to avoid GitHub push protection.',
                                                                          detected: false, pattern: nil },
  { provider: 'doppler',    key_type: 'service_token',    value: "dp.st.dev.#{'a' * 43}",
    notes: 'Doppler service token (dp.st. prefix), per Doppler docs',     detected: false, pattern: nil },

  # ── Adversarial fixtures: catch boundary / context-bypass attempts ───
  { provider: 'adversarial', key_type: 'embedded_in_text',
    value: 'sk_test_4eC39HqLyjWDarjtT1zdp7dc',
    notes: 'My deprecated Stripe key sk_test_4eC39HqLyjWDarjtT1zdp7dc was rotated in Q3.',
    detected: true,  pattern: :stripe_secret_key },
  { provider: 'adversarial', key_type: 'multi_secret',
    value: 'AKIAIOSFODNN7EXAMPLE',
    notes: 'config: stripe=sk_test_4eC39HqLyjWDarjtT1zdp7dc aws=AKIAIOSFODNN7EXAMPLE openai=sk-proj-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    detected: true,  pattern: :aws_access_key_id },
  { provider: 'adversarial', key_type: 'json_blob_secret',
    value: 'AKIAIOSFODNN7EXAMPLE',
    notes: '{"old_keys":["AKIAIOSFODNN7EXAMPLE","sk_test_4eC39HqLyjWDarjtT1zdp7dc"]}',
    detected: true,  pattern: :aws_access_key_id }
].freeze

CREDENTIAL_FIXTURES.each do |row|
  Credential.create!(
    provider: row[:provider],
    key_type: row[:key_type],
    value:    row[:value],
    notes:    row[:notes],
    metadata: { 'embedded_copy' => row[:value], 'pattern' => row[:pattern] }.to_json
  )
end

puts "Seeded #{Credential.count} credential rows"
