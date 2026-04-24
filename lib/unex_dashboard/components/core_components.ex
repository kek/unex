defmodule Unex.Dashboard.CoreComponents do
  use Phoenix.Component

  attr(:rows, :list, required: true)

  slot :col, required: true do
    attr(:label, :string)
  end

  def table(assigns) do
    ~H"""
    <table class="min-w-full text-sm">
      <thead class="bg-zinc-100 text-left">
        <tr>
          <th :for={c <- @col} class="px-3 py-2 font-medium">{c.label}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows} class="border-t border-zinc-100">
          <td :for={c <- @col} class="px-3 py-2">{render_slot(c, row)}</td>
        </tr>
      </tbody>
    </table>
    """
  end
end
