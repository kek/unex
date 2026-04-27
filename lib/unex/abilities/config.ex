defmodule Unex.Abilities.Config do
  @moduledoc """
  Encrypted key-value store for secrets, scoped by environment.
  Values are encrypted with AES-256-GCM before storing in Mnesia.
  """

  @table :unex_config

  def table_name, do: @table

  @doc "Stores an encrypted secret."
  def set(env, key, value) when is_binary(env) and is_binary(key) and is_binary(value) do
    ensure_table()
    encrypted = encrypt(value)

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({@table, {env, key}, encrypted})
      end)

    :ok
  end

  @doc "Retrieves and decrypts a secret. Returns `{:ok, value}` or `:not_found`."
  def get(env, key) when is_binary(env) and is_binary(key) do
    ensure_table()

    {:atomic, result} =
      :mnesia.transaction(fn ->
        :mnesia.read(@table, {env, key})
      end)

    case result do
      [{@table, _, encrypted}] -> {:ok, decrypt(encrypted)}
      [] -> :not_found
    end
  end

  @doc "Deletes a secret."
  def delete(env, key) do
    ensure_table()

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.delete({@table, {env, key}})
      end)

    :ok
  end

  @doc "Lists all keys for an environment."
  def list(env) do
    ensure_table()

    {:atomic, records} =
      :mnesia.transaction(fn ->
        :mnesia.match_object({@table, {env, :_}, :_})
      end)

    Enum.map(records, fn {_, {_env, key}, _} -> key end)
  end

  defp ensure_table do
    Unex.Storage.Schema.ensure_table!(@table, type: :set, attributes: [:key, :value])
  end

  defp encryption_key do
    configured = Application.get_env(:unex, :config_encryption_key)

    unless configured do
      raise "No encryption key configured. Set UNEX_CONFIG_KEY environment variable."
    end

    :crypto.hash(:sha256, configured)
  end

  defp encrypt(plaintext) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    iv <> tag <> ciphertext
  end

  defp decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = encryption_key()
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false)
  end
end
