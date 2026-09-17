import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

# Existing AgentRunner integration tests drive the Codex app-server stub.
# Outside tests the runner comes from `agent.runner` in WORKFLOW.md
# (see SymphonyElixir.Config.agent_runner_module/0).
if config_env() == :test do
  config :symphony_elixir, :agent_runner_module, SymphonyElixir.Codex.AppServer
end
