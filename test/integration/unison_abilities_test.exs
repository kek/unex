defmodule Unex.Integration.UnisonAbilitiesTest do
  @moduledoc """
  End-to-end tests: Unison programs exercise Unex.Storage, Unex.Config, and Unex.Scratch
  abilities via their HTTP handlers against a live Unex server.
  Each test inlines all required Unison code (helpers + ability + handler + program)
  into a single source string, because run.file loads one file.
  """
  use ExUnit.Case, async: false

  setup_all do
    # 1. Init Mnesia for storage + config
    #    (Scratch and Log GenServers are already started by the application supervisor)
    mnesia_dir =
      Path.join(
        System.tmp_dir!(),
        "unex_unison_abilities_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(mnesia_dir)
    Unex.Storage.Schema.init(mnesia_dir)

    # 2. Bandit on an ephemeral localhost port — avoids colliding with a
    # running dev server holding 127.0.0.1 on a hard-coded port.
    {:ok, bandit_pid} =
      Bandit.start_link(plug: Unex.API.Router, port: 0, ip: {127, 0, 0, 1})

    {:ok, {_addr, port}} = ThousandIsland.listener_info(bandit_pid)

    on_exit(fn ->
      Process.exit(bandit_pid, :normal)
      :mnesia.stop()
      File.rm_rf!(mnesia_dir)
    end)

    {:ok, port: port}
  end

  defp test_secret, do: Application.get_env(:unex, :api_secret)

  @tag timeout: 300_000
  test "Unex.Storage ability: create DB, write, read", %{port: port} do
    secret = test_secret()

    source = """
    use lib.unison_http_15_2_0
    use lib.base.IO

    authHeader : HttpRequest -> HttpRequest
    authHeader req = HttpRequest.addHeader "Authorization" "Bearer #{secret}" req

    postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
    postJson url body = Http.request (authHeader (HttpRequest.addHeader "Content-Type" "application/json" (HttpRequest.post (URI.parse url) (Body.fromText body))))

    postEmpty : Text -> {IO, Exception, Http, Threads} HttpResponse
    postEmpty url = Http.request (authHeader (HttpRequest.post (URI.parse url) Body.empty))

    toJson : [(Text, Text)] -> Text
    toJson pairs =
      entries = List.map (cases (k, v) -> "\\"" ++ k ++ "\\":\\"" ++ v ++ "\\"") pairs
      "{" ++ Text.join "," entries ++ "}"

    parseValue : HttpResponse -> Optional Text
    parseValue resp =
      body = bodyText resp
      needle = "\\"value\\":\\""
      match Text.indexOf needle body with
        None -> None
        Some idx ->
          afterKey = Text.drop (idx + Text.size needle) body
          match Text.indexOf "\\"" afterKey with
            None -> None
            Some endIdx -> Some (Text.take endIdx afterKey)

    unique ability Unex.Storage where
      createDatabase : Text -> ()
      createTable : Text -> Text -> ()
      write : Text -> Text -> Text -> Text -> ()
      read : Text -> Text -> Text -> Optional Text

    Unex.Storage.handler : Text -> Request {Unex.Storage} a -> {IO, Exception, Http, Threads} a
    Unex.Storage.handler baseUrl = cases
      { Unex.Storage.createDatabase name -> k } ->
        _ = postJson (baseUrl ++ "/databases") (toJson [("name", name)])
        handle k () with Unex.Storage.handler baseUrl
      { Unex.Storage.createTable db table -> k } ->
        _ = postEmpty (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table)
        handle k () with Unex.Storage.handler baseUrl
      { Unex.Storage.write db table key value -> k } ->
        _ = postJson (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/write") (toJson [("key", key), ("value", value)])
        handle k () with Unex.Storage.handler baseUrl
      { Unex.Storage.read db table key -> k } ->
        resp = Http.request (authHeader (HttpRequest.get (URI.parse (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/read/" ++ key))))
        val = parseValue resp
        handle k val with Unex.Storage.handler baseUrl
      { a } -> a

    main : '{IO, Exception} ()
    main = do
      base = "http://127.0.0.1:#{port}"
      Threads.run do Http.run do
        handle !(do
          Unex.Storage.createDatabase "abilitydb"
          Unex.Storage.createTable "abilitydb" "kv"
          Unex.Storage.write "abilitydb" "kv" "greeting" "hello-from-ability"
          result = Unex.Storage.read "abilitydb" "kv" "greeting"
          match result with
            None -> printLine "NOT_FOUND"
            Some v -> printLine v
        ) with Unex.Storage.handler base
    """

    assert {:ok, result} = Unex.eval(source, timeout: 120_000)
    stdout = Unex.UCM.Output.strip_ansi(result.stdout)
    assert stdout =~ "hello-from-ability"
  end

  @tag timeout: 300_000
  test "Unex.Config ability: set and get a secret", %{port: port} do
    secret = test_secret()

    source = """
    use lib.unison_http_15_2_0
    use lib.base.IO

    authHeader : HttpRequest -> HttpRequest
    authHeader req = HttpRequest.addHeader "Authorization" "Bearer #{secret}" req

    postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
    postJson url body = Http.request (authHeader (HttpRequest.addHeader "Content-Type" "application/json" (HttpRequest.post (URI.parse url) (Body.fromText body))))

    toJson : [(Text, Text)] -> Text
    toJson pairs =
      entries = List.map (cases (k, v) -> "\\"" ++ k ++ "\\":\\"" ++ v ++ "\\"") pairs
      "{" ++ Text.join "," entries ++ "}"

    parseValue : HttpResponse -> Optional Text
    parseValue resp =
      body = bodyText resp
      needle = "\\"value\\":\\""
      match Text.indexOf needle body with
        None -> None
        Some idx ->
          afterKey = Text.drop (idx + Text.size needle) body
          match Text.indexOf "\\"" afterKey with
            None -> None
            Some endIdx -> Some (Text.take endIdx afterKey)

    unique ability Unex.Config where
      set : Text -> Text -> Text -> ()
      get : Text -> Text -> Optional Text

    Unex.Config.handler : Text -> Request {Unex.Config} a -> {IO, Exception, Http, Threads} a
    Unex.Config.handler baseUrl = cases
      { Unex.Config.set env key value -> k } ->
        _ = postJson (baseUrl ++ "/config/" ++ env ++ "/" ++ key) (toJson [("value", value)])
        handle k () with Unex.Config.handler baseUrl
      { Unex.Config.get env key -> k } ->
        resp = Http.request (authHeader (HttpRequest.get (URI.parse (baseUrl ++ "/config/" ++ env ++ "/" ++ key))))
        val = parseValue resp
        handle k val with Unex.Config.handler baseUrl
      { a } -> a

    main : '{IO, Exception} ()
    main = do
      base = "http://127.0.0.1:#{port}"
      Threads.run do Http.run do
        handle !(do
          Unex.Config.set "prod" "db_password" "supersecret42"
          result = Unex.Config.get "prod" "db_password"
          match result with
            None -> printLine "NOT_FOUND"
            Some v -> printLine v
        ) with Unex.Config.handler base
    """

    assert {:ok, result} = Unex.eval(source, timeout: 120_000)
    stdout = Unex.UCM.Output.strip_ansi(result.stdout)
    assert stdout =~ "supersecret42"
  end

  @tag timeout: 300_000
  test "Unex.Scratch ability: put and get ephemeral value", %{port: port} do
    secret = test_secret()

    source = """
    use lib.unison_http_15_2_0
    use lib.base.IO

    authHeader : HttpRequest -> HttpRequest
    authHeader req = HttpRequest.addHeader "Authorization" "Bearer #{secret}" req

    postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
    postJson url body = Http.request (authHeader (HttpRequest.addHeader "Content-Type" "application/json" (HttpRequest.post (URI.parse url) (Body.fromText body))))

    toJson : [(Text, Text)] -> Text
    toJson pairs =
      entries = List.map (cases (k, v) -> "\\"" ++ k ++ "\\":\\"" ++ v ++ "\\"") pairs
      "{" ++ Text.join "," entries ++ "}"

    parseValue : HttpResponse -> Optional Text
    parseValue resp =
      body = bodyText resp
      needle = "\\"value\\":\\""
      match Text.indexOf needle body with
        None -> None
        Some idx ->
          afterKey = Text.drop (idx + Text.size needle) body
          match Text.indexOf "\\"" afterKey with
            None -> None
            Some endIdx -> Some (Text.take endIdx afterKey)

    unique ability Unex.Scratch where
      put : Text -> Text -> ()
      get : Text -> Optional Text

    Unex.Scratch.handler : Text -> Request {Unex.Scratch} a -> {IO, Exception, Http, Threads} a
    Unex.Scratch.handler baseUrl = cases
      { Unex.Scratch.put key value -> k } ->
        _ = postJson (baseUrl ++ "/scratch/" ++ key) (toJson [("value", value)])
        handle k () with Unex.Scratch.handler baseUrl
      { Unex.Scratch.get key -> k } ->
        resp = Http.request (authHeader (HttpRequest.get (URI.parse (baseUrl ++ "/scratch/" ++ key))))
        val = parseValue resp
        handle k val with Unex.Scratch.handler baseUrl
      { a } -> a

    main : '{IO, Exception} ()
    main = do
      base = "http://127.0.0.1:#{port}"
      Threads.run do Http.run do
        handle !(do
          Unex.Scratch.put "session:xyz" "temp-token-999"
          result = Unex.Scratch.get "session:xyz"
          match result with
            None -> printLine "NOT_FOUND"
            Some v -> printLine v
        ) with Unex.Scratch.handler base
    """

    assert {:ok, result} = Unex.eval(source, timeout: 120_000)
    stdout = Unex.UCM.Output.strip_ansi(result.stdout)
    assert stdout =~ "temp-token-999"
  end
end
