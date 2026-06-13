import Config

# Route ExSanity HTTP calls through a Req.Test plug so tests never hit the
# network. The stub name (ExSanity) matches the default :req_stub.
config :ex_sanity, :ex_sanity_req_options, plug: {Req.Test, ExSanity}

config :ex_sanity, :ex_sanity,
  project_id: "test-project",
  dataset: "test",
  api_version: "2024-01-01",
  write_token: "test-write-token"
