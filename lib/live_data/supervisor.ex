defmodule LiveData.Supervisor do
  use Supervisor

  def start_link(_) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [LiveData.Parent]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
