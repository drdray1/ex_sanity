import Config

# Environment-specific config (e.g. test stubs) is imported here.
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
