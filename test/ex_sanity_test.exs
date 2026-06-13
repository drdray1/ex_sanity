defmodule ExSanityTest do
  use ExUnit.Case, async: true

  setup do
    Req.Test.set_req_test_from_context(%{async: true})
    :ok
  end

  describe "query/3" do
    test "returns the result on success" do
      Req.Test.stub(ExSanity, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2024-01-01/data/query/test"

        Req.Test.json(conn, %{"result" => [%{"_id" => "a", "title" => "Hello"}]})
      end)

      assert {:ok, [%{"title" => "Hello"}]} = ExSanity.query("*[_type == \"post\"]")
    end

    test "passes params in the request body" do
      Req.Test.stub(ExSanity, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["params"] == %{"slug" => "my-post"}

        Req.Test.json(conn, %{"result" => %{"_id" => "x"}})
      end)

      assert {:ok, %{"_id" => "x"}} =
               ExSanity.query("*[slug.current == $slug][0]", %{slug: "my-post"})
    end

    test "maps 401 to :unauthorized" do
      Req.Test.stub(ExSanity, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "no"})
      end)

      assert {:error, :unauthorized} = ExSanity.query("*")
    end

    test "maps 429 to :rate_limited" do
      Req.Test.stub(ExSanity, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "slow down"})
      end)

      assert {:error, :rate_limited} = ExSanity.query("*")
    end

    test "maps 5xx to :server_error" do
      Req.Test.stub(ExSanity, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:server_error, 500, _}} = ExSanity.query("*")
    end

    test "errors on an unexpected response shape" do
      Req.Test.stub(ExSanity, fn conn ->
        Req.Test.json(conn, %{"notResult" => true})
      end)

      assert {:error, {:unexpected_response, _}} = ExSanity.query("*")
    end
  end

  describe "mutate/2" do
    test "posts mutations and returns the body" do
      Req.Test.stub(ExSanity, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2024-01-01/data/mutate/test"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert [%{"create" => %{"_type" => "post"}}] = decoded["mutations"]

        Req.Test.json(conn, %{"results" => [%{"id" => "new-id"}]})
      end)

      assert {:ok, %{"results" => [%{"id" => "new-id"}]}} =
               ExSanity.create_doc(%{"_type" => "post", "title" => "T"})
    end

    test "sends a bearer token from the write_token config" do
      Req.Test.stub(ExSanity, fn conn ->
        assert ["Bearer test-write-token"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, %{"results" => []})
      end)

      assert {:ok, _} = ExSanity.delete_doc("some-id")
    end

    test "returns :missing_write_token when no token is configured" do
      original = Application.get_env(:ex_sanity, :ex_sanity)
      Application.put_env(:ex_sanity, :ex_sanity, Keyword.delete(original, :write_token))
      on_exit(fn -> Application.put_env(:ex_sanity, :ex_sanity, original) end)

      assert {:error, :missing_write_token} = ExSanity.create_doc(%{"_type" => "post"})
    end
  end

  describe "custom otp_app / config_key" do
    setup do
      Application.put_env(:host_app, :sanity,
        project_id: "test-project",
        dataset: "test",
        write_token: "host-token"
      )

      Application.put_env(:host_app, :sanity_req_options, plug: {Req.Test, ExSanity})
      on_exit(fn -> Application.delete_env(:host_app, :sanity) end)
      :ok
    end

    test "reads config from a host app's own namespace" do
      Req.Test.stub(ExSanity, fn conn ->
        assert ["Bearer host-token"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, %{"results" => []})
      end)

      assert {:ok, _} =
               ExSanity.delete_doc("x", otp_app: :host_app, config_key: :sanity)
    end
  end
end
