defmodule Uniops.Integration.UnisonAbilitiesTest do
  @moduledoc """
  End-to-end tests: Unison programs exercise UStorage, UConfig, and UScratch
  abilities via their HTTP handlers against a live Uniops server.
  Each test inlines all required Unison code (helpers + ability + handler + program)
  into a single source string, because run.file loads one file.
  """
  use ExUnit.Case, async: false

  @test_port 4042

  setup_all do
    # 1. Init Mnesia for storage + config
    #    (Scratch and Log GenServers are already started by the application supervisor)
    mnesia_dir =
      Path.join(
        System.tmp_dir!(),
        "uniops_unison_abilities_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(mnesia_dir)
    Uniops.Storage.Schema.init(mnesia_dir)

    # 2. Start Bandit on a test port
    {:ok, bandit_pid} = Bandit.start_link(plug: Uniops.API.Router, port: @test_port)

    on_exit(fn ->
      Process.exit(bandit_pid, :normal)
      :mnesia.stop()
      File.rm_rf!(mnesia_dir)
    end)

    {:ok, port: @test_port}
  end

  @tag timeout: 300_000
  test "UStorage ability: create DB, write, read", %{port: port} do
    source = """
    use lib.unison_http_15_2_0
    use lib.base.IO

    postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
    postJson url body = Http.request (HttpRequest.addHeader "Content-Type" "application/json" (HttpRequest.post (URI.parse url) (Body.fromText body)))

    postEmpty : Text -> {IO, Exception, Http, Threads} HttpResponse
    postEmpty url = Http.request (HttpRequest.post (URI.parse url) Body.empty)

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

    unique ability UStorage where
      createDatabase : Text -> ()
      createTable : Text -> Text -> ()
      write : Text -> Text -> Text -> Text -> ()
      read : Text -> Text -> Text -> Optional Text

    UStorage.handler : Text -> Request {UStorage} a -> {IO, Exception, Http, Threads} a
    UStorage.handler baseUrl = cases
      { UStorage.createDatabase name -> k } ->
        _ = postJson (baseUrl ++ "/databases") (toJson [("name", name)])
        handle k () with UStorage.handler baseUrl
      { UStorage.createTable db table -> k } ->
        _ = postEmpty (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table)
        handle k () with UStorage.handler baseUrl
      { UStorage.write db table key value -> k } ->
        _ = postJson (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/write") (toJson [("key", key), ("value", value)])
        handle k () with UStorage.handler baseUrl
      { UStorage.read db table key -> k } ->
        resp = Http.get (URI.parse (baseUrl ++ "/databases/" ++ db ++ "/tables/" ++ table ++ "/read/" ++ key))
        val = parseValue resp
        handle k val with UStorage.handler baseUrl
      { a } -> a

    main : '{IO, Exception} ()
    main = do
      base = "http://127.0.0.1:#{port}"
      Threads.run do Http.run do
        handle !(do
          UStorage.createDatabase "abilitydb"
          UStorage.createTable "abilitydb" "kv"
          UStorage.write "abilitydb" "kv" "greeting" "hello-from-ability"
          result = UStorage.read "abilitydb" "kv" "greeting"
          match result with
            None -> printLine "NOT_FOUND"
            Some v -> printLine v
        ) with UStorage.handler base
    """

    assert {:ok, result} = Uniops.eval(source, timeout: 120_000)
    stdout = Uniops.UCM.Output.strip_ansi(result.stdout)
    assert stdout =~ "hello-from-ability"
  end

  @tag timeout: 300_000
  test "UConfig ability: set and get a secret", %{port: port} do
    source = """
    use lib.unison_http_15_2_0
    use lib.base.IO

    postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
    postJson url body = Http.request (HttpRequest.addHeader "Content-Type" "application/json" (HttpRequest.post (URI.parse url) (Body.fromText body)))

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

    unique ability UConfig where
      set : Text -> Text -> Text -> ()
      get : Text -> Text -> Optional Text

    UConfig.handler : Text -> Request {UConfig} a -> {IO, Exception, Http, Threads} a
    UConfig.handler baseUrl = cases
      { UConfig.set env key value -> k } ->
        _ = postJson (baseUrl ++ "/config/" ++ env ++ "/" ++ key) (toJson [("value", value)])
        handle k () with UConfig.handler baseUrl
      { UConfig.get env key -> k } ->
        resp = Http.get (URI.parse (baseUrl ++ "/config/" ++ env ++ "/" ++ key))
        val = parseValue resp
        handle k val with UConfig.handler baseUrl
      { a } -> a

    main : '{IO, Exception} ()
    main = do
      base = "http://127.0.0.1:#{port}"
      Threads.run do Http.run do
        handle !(do
          UConfig.set "prod" "db_password" "supersecret42"
          result = UConfig.get "prod" "db_password"
          match result with
            None -> printLine "NOT_FOUND"
            Some v -> printLine v
        ) with UConfig.handler base
    """

    assert {:ok, result} = Uniops.eval(source, timeout: 120_000)
    stdout = Uniops.UCM.Output.strip_ansi(result.stdout)
    assert stdout =~ "supersecret42"
  end

  @tag timeout: 300_000
  test "UScratch ability: put and get ephemeral value", %{port: port} do
    source = """
    use lib.unison_http_15_2_0
    use lib.base.IO

    postJson : Text -> Text -> {IO, Exception, Http, Threads} HttpResponse
    postJson url body = Http.request (HttpRequest.addHeader "Content-Type" "application/json" (HttpRequest.post (URI.parse url) (Body.fromText body)))

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

    unique ability UScratch where
      put : Text -> Text -> ()
      get : Text -> Optional Text

    UScratch.handler : Text -> Request {UScratch} a -> {IO, Exception, Http, Threads} a
    UScratch.handler baseUrl = cases
      { UScratch.put key value -> k } ->
        _ = postJson (baseUrl ++ "/scratch/" ++ key) (toJson [("value", value)])
        handle k () with UScratch.handler baseUrl
      { UScratch.get key -> k } ->
        resp = Http.get (URI.parse (baseUrl ++ "/scratch/" ++ key))
        val = parseValue resp
        handle k val with UScratch.handler baseUrl
      { a } -> a

    main : '{IO, Exception} ()
    main = do
      base = "http://127.0.0.1:#{port}"
      Threads.run do Http.run do
        handle !(do
          UScratch.put "session:xyz" "temp-token-999"
          result = UScratch.get "session:xyz"
          match result with
            None -> printLine "NOT_FOUND"
            Some v -> printLine v
        ) with UScratch.handler base
    """

    assert {:ok, result} = Uniops.eval(source, timeout: 120_000)
    stdout = Uniops.UCM.Output.strip_ansi(result.stdout)
    assert stdout =~ "temp-token-999"
  end
end
