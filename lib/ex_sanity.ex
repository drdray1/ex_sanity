defmodule ExSanity do
  @moduledoc """
  A thin HTTP client for the [Sanity.io](https://www.sanity.io) content platform.

  Covers the two HTTP APIs you need to read and write content:

    * `POST /data/query/{dataset}` — [GROQ](https://www.sanity.io/docs/groq) queries
      (reads). Public datasets need no token; private datasets / draft access use a
      read token.
    * `POST /data/mutate/{dataset}` — document mutations (writes). Requires a token
      with the Editor role.

  The client is stateless and uses [Req](https://hexdocs.pm/req) directly with bearer
  auth and status-based pattern matching. HTTP behaviour is configurable (and so
  test-mockable via `Req.Test`).

  ## Configuration

  Configure under the `:ex_sanity` application environment:

      config :ex_sanity, :ex_sanity,
        project_id: "your-project-id",
        dataset: "production",
        api_version: "2024-01-01",
        read_token: "...",   # optional; only for private datasets / drafts
        write_token: "..."   # required for mutations

  ## Usage

      {:ok, posts} = ExSanity.query(~s|*[_type == "post"]{title}|)
      {:ok, post}  = ExSanity.query("*[slug.current == $slug][0]", %{slug: "hello"})

      {:ok, _} = ExSanity.create_doc(%{"_type" => "post", "title" => "Hello"})
      {:ok, _} = ExSanity.create_or_replace(%{"_id" => "landing", "_type" => "page"})
      {:ok, _} = ExSanity.patch_doc("doc-id", %{"title" => "Updated"})
      {:ok, _} = ExSanity.delete_doc("doc-id")

  ## Options

  Every public function accepts an optional trailing keyword list so the client can
  be embedded in a host app that keeps its own config namespace:

    * `:otp_app`    — application to read config from (default `:ex_sanity`)
    * `:config_key` — key within that app holding the config map
      (default `:ex_sanity`)
    * `:req_stub`   — `Req.Test` plug name; the request options are read from
      `Application.get_env(otp_app, :"\#{config_key}_req_options")` (default
      `ExSanity`)

  For example, a host app `:my_app` storing config under `:sanity` would call
  `ExSanity.query(groq, %{}, otp_app: :my_app, config_key: :sanity)`.
  """
  require Logger

  @default_opts [otp_app: :ex_sanity, config_key: :ex_sanity, req_stub: __MODULE__]

  @doc """
  Run a GROQ `query` against the configured dataset.

  `params` is a map of GROQ query parameters (referenced as `$name` in the query).
  Returns `{:ok, result}` where `result` is the decoded value of the response's
  `"result"` key, or `{:error, reason}`.
  """
  def query(query, params \\ %{}, opts \\ []) when is_binary(query) do
    cfg = config(opts)
    body = %{query: query, params: params}

    req_opts =
      [headers: headers(cfg[:read_token]), json: body, receive_timeout: 30_000]
      |> Keyword.merge(req_options(opts))

    case Req.post("#{base_url(cfg)}/data/query/#{dataset(cfg)}", req_opts) do
      {:ok, %{status: status, body: %{"result" => result}}} when status in 200..299 ->
        {:ok, result}

      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        Logger.error("ExSanity query: unexpected response shape #{inspect(resp_body)}")
        {:error, {:unexpected_response, resp_body}}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("ExSanity query failed: status=#{status} body=#{inspect(resp_body)}")
        {:error, error_reason(status, resp_body)}

      {:error, reason} ->
        Logger.error("ExSanity query request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Submit a list of `mutations` to the dataset.

  Each mutation is a map in Sanity's mutation format, e.g.
  `%{create: doc}`, `%{createOrReplace: doc}`,
  `%{patch: %{id: id, set: %{...}}}`, or `%{delete: %{id: id}}`.

  Returns `{:ok, body}` with the mutation result (includes `"results"` with document
  ids) or `{:error, reason}`. Requires a configured `write_token`; returns
  `{:error, :missing_write_token}` if none is set.
  """
  def mutate(mutations, opts \\ []) when is_list(mutations) do
    cfg = config(opts)

    case cfg[:write_token] do
      token when is_binary(token) and token != "" ->
        do_mutate(mutations, token, cfg, opts)

      _ ->
        {:error, :missing_write_token}
    end
  end

  defp do_mutate(mutations, token, cfg, opts) do
    # `returnIds`/`returnDocuments` keep the response useful for the caller.
    body = %{mutations: mutations}

    req_opts =
      [
        headers: headers(token),
        json: body,
        params: [returnIds: true, returnDocuments: true],
        receive_timeout: 30_000
      ]
      |> Keyword.merge(req_options(opts))

    case Req.post("#{base_url(cfg)}/data/mutate/#{dataset(cfg)}", req_opts) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("ExSanity mutate failed: status=#{status} body=#{inspect(resp_body)}")
        {:error, error_reason(status, resp_body)}

      {:error, reason} ->
        Logger.error("ExSanity mutate request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Create a new document. Sanity assigns an id when `doc` has none."
  def create_doc(doc, opts \\ []) when is_map(doc), do: mutate([%{create: doc}], opts)

  @doc """
  Create-or-replace a document. `doc` must include an `_id`. This is the simplest
  upsert for singletons and edited documents.
  """
  def create_or_replace(doc, opts \\ []) when is_map(doc),
    do: mutate([%{createOrReplace: doc}], opts)

  @doc "Patch (partial update) a document by id with a `set` map."
  def patch_doc(id, set, opts \\ []) when is_binary(id) and is_map(set),
    do: mutate([%{patch: %{id: id, set: set}}], opts)

  @doc "Delete a document by id."
  def delete_doc(id, opts \\ []) when is_binary(id), do: mutate([%{delete: %{id: id}}], opts)

  # --- config + helpers ----------------------------------------------------

  defp headers(nil), do: [{"content-type", "application/json"}]
  defp headers(""), do: [{"content-type", "application/json"}]

  defp headers(token) when is_binary(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"}
    ]
  end

  defp base_url(cfg) do
    "https://#{cfg[:project_id]}.api.sanity.io/v#{api_version(cfg)}"
  end

  defp dataset(cfg), do: cfg[:dataset] || "production"
  defp api_version(cfg), do: cfg[:api_version] || "2024-01-01"

  defp config(opts) do
    opts = Keyword.merge(@default_opts, opts)
    Application.get_env(opts[:otp_app], opts[:config_key], [])
  end

  defp req_options(opts) do
    opts = Keyword.merge(@default_opts, opts)
    key = :"#{opts[:config_key]}_req_options"
    Application.get_env(opts[:otp_app], key, [])
  end

  defp error_reason(401, _body), do: :unauthorized
  defp error_reason(403, _body), do: :forbidden
  defp error_reason(404, _body), do: :not_found
  defp error_reason(429, _body), do: :rate_limited

  defp error_reason(status, body) when status >= 500, do: {:server_error, status, body}
  defp error_reason(status, body), do: {:http_error, status, body}
end
