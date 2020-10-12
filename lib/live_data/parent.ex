defmodule LiveData.Parent do
  use Parent.GenServer

  @impl GenServer
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    Parent.GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_child(module, id, meta \\ %{}) do
    Parent.start_child(Parent.child_spec(module, id: id, meta: meta))
  end

  def child_pid(id) do
    Parent.Client.child_pid(__MODULE__, id)
  end
end
