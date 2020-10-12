# defmodule LiveData.Channel do
#   @moduledoc false
#   use GenServer, restart: :temporary

#   require Logger
#   alias Phoenix.Socket.Message

#   @prefix :live_data

#   def start_link({endpoint, from}) do
#     hibernate_after = endpoint.config(:live_view)[:hibernate_after] || 15000
#     opts = [hibernate_after: hibernate_after]
#     GenServer.start_link(__MODULE__, from, opts)
#   end

#   def send_update(module, id, assigns) do
#     send(self(), {@prefix, :send_update, {module, id, assigns}})
#   end

#   def send_update_after(module, id, assigns, time_in_milliseconds)
#       when is_integer(time_in_milliseconds) do
#     Process.send_after(
#       self(),
#       {@prefix, :send_update, {module, id, assigns}},
#       time_in_milliseconds
#     )
#   end

#   @impl true
#   def init({pid, _ref}) do
#     {:ok, Process.monitor(pid)}
#   end

#   @impl true
#   def handle_info({Phoenix.Channel, auth_payload, from, phx_socket}, ref) do
#     Process.demonitor(ref)
#     mount(auth_payload, from, phx_socket)
#   rescue
#     # Normalize exceptions for better client debugging
#     e -> reraise(e, __STACKTRACE__)
#   end

#   def handle_info({:DOWN, ref, _, _, _reason}, ref) do
#     {:stop, {:shutdown, :closed}, ref}
#   end

#   def handle_info({:DOWN, _, _, transport_pid, _reason}, %{transport_pid: transport_pid} = state) do
#     {:stop, {:shutdown, :closed}, state}
#   end

#   def handle_info({:DOWN, _, _, parent, reason}, %{socket: %{parent_pid: parent}} = state) do
#     send(state.transport_pid, {:socket_close, self(), reason})
#     {:stop, {:shutdown, :parent_exited}, state}
#   end

#   def handle_info(%Message{topic: topic, event: "phx_leave"} = msg, %{topic: topic} = state) do
#     reply(state, msg.ref, :ok, %{})
#     {:stop, {:shutdown, :left}, state}
#   end

#   def handle_info({@prefix, :send_update, update}, state) do
#     # case Diff.update_component(state.socket, state.components, update) do
#     #   {diff, new_components} ->
#     #     {:noreply, push_diff(%{state | components: new_components}, diff, nil)}

#     #   :noop ->
#     #     {module, id, _} = update

#     #     if function_exported?(module, :__info__, 1) do
#     #       # Only a warning, because there can be race conditions where a component is removed before a `send_update` happens.
#     #       Logger.debug(
#     #         "send_update failed because component #{inspect(module)} with ID #{inspect(id)} does not exist or it has been removed"
#     #       )
#     #     else
#     #       raise ArgumentError, "send_update failed (module #{inspect(module)} is not available)"
#     #     end

#     #     {:noreply, state}
#     # end
#   end

#   def handle_call({@prefix, :ping}, _from, state) do
#     {:reply, :ok, state}
#   end
# end
