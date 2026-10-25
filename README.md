# ExSanity

A thin, dependency-light Elixir client for the [Sanity.io](https://www.sanity.io)
content platform. It wraps the two HTTP APIs you need to read and write content:

- **GROQ queries** (`POST /data/query/{dataset}`) — reads
- **Mutations** (`POST /data/mutate/{dataset}`) — writes (create, replace, patch, delete)

Built on [Req](https://hexdocs.pm/req). The client is stateless, so there's nothing
to start in your supervision tree — just configure and call.

## Installation

Add `ex_sanity` to your `mix.exs`. From GitHub:

```elixir
def deps do
  [
    {:ex_sanity, git: "https://github.com/drdray1/ex_sanity.git", tag: "v0.1.1"}
  ]
end
```

## Configuration

```elixir
config :ex_sanity, :ex_sanity,
  project_id: "your-project-id",
  dataset: "production",
  api_version: "2024-01-01",
  read_token: "...",   # optional; only for private datasets / drafts
  write_token: "..."   # required for mutations
```

## Usage

### Querying (GROQ)

```elixir
{:ok, posts} = ExSanity.query(~s|*[_type == "post"]{title, "slug": slug.current}|)

# With parameters
{:ok, post} = ExSanity.query("*[slug.current == $slug][0]", %{slug: "hello-world"})
```

`query/3` returns `{:ok, result}` (the decoded value of the response's `"result"`
key) or `{:error, reason}`.

### Mutating

```elixir
{:ok, _} = ExSanity.create_doc(%{"_type" => "post", "title" => "Hello"})
{:ok, _} = ExSanity.create_or_replace(%{"_id" => "landing", "_type" => "page", "title" => "Home"})
{:ok, _} = ExSanity.patch_doc("doc-id", %{"title" => "Updated title"})
{:ok, _} = ExSanity.delete_doc("doc-id")

# Or submit raw mutations
{:ok, _} = ExSanity.mutate([%{create: %{"_type" => "post"}}, %{delete: %{id: "old"}}])
```

Mutations require a `write_token`; without one you'll get `{:error, :missing_write_token}`.

## Error tuples

`{:error, reason}` where `reason` is one of:

| reason | meaning |
|---|---|
| `:unauthorized` | 401 — bad/missing token |
| `:forbidden` | 403 |
| `:not_found` | 404 |
| `:rate_limited` | 429 |
| `{:server_error, status, body}` | 5xx |
| `{:http_error, status, body}` | other non-2xx |
| `{:unexpected_response, body}` | 2xx without a `"result"` key (query) |
| `:missing_write_token` | a mutation was attempted with no write token |

## Embedding in a host app's config namespace

Every function accepts a trailing options keyword list so a host application can
keep its own config key instead of `:ex_sanity`:

```elixir
config :my_app, :sanity,
  project_id: "...",
  dataset: "production",
  write_token: "..."

ExSanity.query(groq, %{}, otp_app: :my_app, config_key: :sanity)
```

Options:

- `:otp_app` — application to read config from (default `:ex_sanity`)
- `:config_key` — key within that app holding the config map (default `:ex_sanity`)
- `:req_stub` — `Req.Test` plug name for testing (default `ExSanity`); request
  options are read from `Application.get_env(otp_app, :"\#{config_key}_req_options")`

## Testing

Route HTTP through a `Req.Test` plug — no network needed:

```elixir
config :ex_sanity, :ex_sanity_req_options, plug: {Req.Test, ExSanity}
```

```elixir
Req.Test.stub(ExSanity, fn conn ->
  Req.Test.json(conn, %{"result" => [%{"title" => "Hello"}]})
end)

assert {:ok, [%{"title" => "Hello"}]} = ExSanity.query("*[_type == \"post\"]")
```

## License

MIT
