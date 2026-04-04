defmodule Uniops.API.TransactionController do
  @moduledoc """
  HTTP controller for transactional batch operations.
  """

  alias Uniops.Storage.Transaction
  alias Uniops.API.Json

  def execute(conn, db) do
    {:ok, %{"operations" => ops}} = Json.read_json(conn)

    parsed_ops = Enum.map(ops, &parse_op/1)

    case Transaction.execute(db, parsed_ops) do
      {:ok, _results} ->
        Json.send_json(conn, 200, %{status: "committed"})

      {:error, reason} ->
        Json.send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  defp parse_op(%{"op" => "write_table", "table" => t, "key" => k, "value" => v}) do
    {:write_table, t, k, v}
  end

  defp parse_op(%{"op" => "delete_table", "table" => t, "key" => k}) do
    {:delete_table, t, k}
  end

  defp parse_op(%{"op" => "write_cell", "name" => n, "value" => v}) do
    {:write_cell, n, v}
  end
end
