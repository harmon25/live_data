defmodule LiveData.Server do
  def synchronize(endpoint, old_state, new_state, name) do
    diff = JSONDiff.diff(old_state, new_state)

    if diff != [] do
      endpoint.broadcast(name, "diff", %{
        diff: diff
      })
    end
  end
end

defmodule LiveData do
  @type from :: {pid, tag :: term}

  @callback __live_data_init__(init_arg :: term) ::
              {:ok, state}
              | {:ok, state, timeout | :hibernate | {:continue, term}}
              | :ignore
              | {:stop, reason :: any}
            when state: any

  @callback __live_data_handle_call__(request :: term, from, state :: term) ::
              {:reply, reply, new_state}
              | {:reply, reply, new_state, timeout | :hibernate | {:continue, term}}
              | {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, term}}
              | {:stop, reason, reply, new_state}
              | {:stop, reason, new_state}
            when reply: term, new_state: term, reason: term

  @callback __live_data_handle_cast__(request :: term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, term}}
              | {:stop, reason :: term, new_state}
            when new_state: term
  @callback __live_data_handle_info__(msg :: :timeout | term, state :: term) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, term}}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @optional_callbacks __live_data_handle_info__: 2,
                      __live_data_handle_cast__: 2,
                      __live_data_handle_call__: 3

  defmacro __using__(opts) do
    quote do
      @endpoint Keyword.get(unquote(opts), :endpoint)
      @types_output_path Keyword.get(unquote(opts), :types_output_path, false)
      @state_output_path Keyword.get(unquote(opts), :state_output_path, false)
      @default_state Keyword.get(unquote(opts), :default_state, %{})
      @allowed_keys Enum.map(
                      Map.keys(@default_state),
                      &to_string(&1)
                    )

      defmodule Channel do
        use Phoenix.Channel
        require Logger
        @default_state Keyword.get(unquote(opts), :default_state, %{})
        @allowed_keys Enum.map(
                        Map.keys(@default_state),
                        &to_string(&1)
                      )

        def join(name, %{"prevState" => prev_state} = params, socket) do
          prev_s = Morphix.atomorphify!(prev_state, @allowed_keys)
          # need to expose this somehow to allow for authentication/authorization logic
          send(self(), {:after_join, name, %{params | "prevState" => prev_s}})

          {:ok, socket}
        end

        def join(name, params, socket) do
          # need to expose this somehow to allow for authentication/authorization logic
          send(self(), {:after_join, name, params})

          {:ok, socket}
        end

        @parent __MODULE__
                |> to_string
                |> String.split(".")
                |> Enum.drop(-1)
                |> Enum.join(".")
                |> String.to_atom()

        def handle_info({:after_join, name, params}, socket) do
          # actually use the Parent module to start/lookup a supervisor for this channel "App:*"
          parent_module =
            __MODULE__
            |> to_string
            |> String.split(".")
            |> Enum.drop(-1)
            |> Enum.join(".")
            |> String.to_atom()

          pid =
            case GenServer.whereis({:global, "#{parent_module}_#{name}"}) do
              nil ->
                Logger.debug("Starting LiveData Process: #{name}")

                {:ok, pid} =
                  GenServer.start(
                    parent_module,
                    [name, params],
                    name: {:global, "#{parent_module}_#{name}"}
                  )

                pid

              pid ->
                send(pid, :__live_data_init__)
                pid
            end

          send(pid, {:__live_data_monitor__, self()})
          {:noreply, assign(socket, :pid, pid)}
        end

        def handle_in(method, params, socket) do
          GenServer.call(
            socket.assigns.pid,
            {String.to_existing_atom(method), params}
          )

          {:noreply, socket}
        end
      end

      # this needs to be here?
      use GenServer
      require Logger
      @default_state Keyword.get(unquote(opts), :default_state, %{})

      # def start_link(default_state) when is_list(default) do
      #   GenServer.start_link(__MODULE__, %{defaultState: default})
      # end

      def handle_info({:__live_data_monitor__, child_pid}, {state, name, pids}) do
        Process.monitor(child_pid)
        {:noreply, {state, name, [child_pid | pids]}}
      end

      def handle_info(:__live_data_init__, {state, name, pids}) do
        _ = LiveData.Server.synchronize(@endpoint, %{}, serialize(state), name)

        {:noreply, {state, name, pids}}
      end

      def handle_info(msg, {state, name, pids}) do
        pids =
          case msg do
            {:DOWN, _ref, :process, object, _reason} ->
              pids |> List.delete(object)

            _ ->
              pids
          end

        if pids == [] do
          Logger.debug("Exiting LiveData Process: #{name}")
          Process.exit(self(), :normal)
        end

        {:noreply, new_state} = __live_data_handle_info__(msg, state)
        _ = LiveData.Server.synchronize(@endpoint, serialize(state), serialize(new_state), name)
        {:noreply, {new_state, name, pids}}
      end

      def handle_cast(msg, {state, name, pids}) do
        case __live_data_handle_cast__(msg, state) do
          {:noreply, new_state} ->
            _ =
              LiveData.Server.synchronize(@endpoint, serialize(state), serialize(new_state), name)

            {:noreply, {new_state, name, pids}}

          e ->
            e
        end
      end

      def handle_call(:__live_data_current_state, _from, {current_state, _} = state) do
        {:reply, current_state, state}
      end

      def handle_call(msg, from, {state, name, pids}) do
        case __live_data_handle_call__(msg, from, state) do
          {:reply, reply, new_state} ->
            _ =
              LiveData.Server.synchronize(@endpoint, serialize(state), serialize(new_state), name)

            {:reply, reply, {new_state, name, pids}}

          e ->
            e
        end
      end

      def init([name, init_arg]) do
        {:ok, state} =
          case Keyword.has_key?(__MODULE__.__info__(:functions), :__live_data_init__) do
            true ->
              __MODULE__.__live_data_init__(init_arg)

            false ->
              {:ok, init_arg}
          end

        _ = LiveData.Server.synchronize(@endpoint, %{}, serialize(state), name)

        {:ok, {state, name, []}}
      end

      Module.register_attribute(__MODULE__, :callbacks, accumulate: true)
      @on_definition LiveData
      @before_compile LiveData
    end
  end

  # TODO
  # not sure really sure how to do this macro stuff, breaking up the server api to be seperate but similar to a gen_server callback?
  # def __on_definition__(env, kind, :handle_mount, args, guards, body) do
  #   Module.put_attribute(env.module, :callbacks, {kind, :handle_mount, args, guards, body})
  # end

  # def __on_definition__(env, kind, :handle_action, args, guards, body) do
  #   Module.put_attribute(env.module, :callbacks, {kind, :handle_action, args, guards, body})
  # end

  def __on_definition__(env, kind, :handle_info, args, guards, body) do
    Module.put_attribute(env.module, :callbacks, {kind, :handle_info, args, guards, body})
  end

  def __on_definition__(env, kind, :handle_call, args, guards, body) do
    Module.put_attribute(env.module, :callbacks, {kind, :handle_call, args, guards, body})
  end

  def __on_definition__(env, kind, :handle_cast, args, guards, body) do
    Module.put_attribute(env.module, :callbacks, {kind, :handle_cast, args, guards, body})
  end

  def __on_definition__(env, kind, :init, args, guards, body) do
    Module.put_attribute(env.module, :callbacks, {kind, :init, args, guards, body})
  end

  def __on_definition__(_env, _kind, _fun, _args, _guards, _body), do: nil

  defmacro __before_compile__(env) do
    handlers =
      Module.get_attribute(env.module, :callbacks)
      |> Enum.map(&wrap_handler/1)

    quote do
      if @types_output_path do
        Path.dirname(unquote(env.file))
        |> Path.join(@types_output_path)
        |> Path.join(Path.basename(unquote(env.file), ".ex") <> ".ts")
        |> File.write(LiveData.TypespecParser.to_ts(@spec))
      end

      if @state_output_path do
        name =
          __MODULE__
          |> to_string
          |> String.split(".")
          |> List.last()

        Path.dirname(unquote(env.file))
        |> Path.join(@state_output_path)
        |> Path.join(Path.basename(unquote(env.file), ".ex") <> ".json")
        |> File.write(Jason.encode!(%{name => @default_state}))
      end

      unquote(handlers)

      def __live_data_handle_call__(msg, _from, state) do
        proc =
          case Process.info(self(), :registered_name) do
            {_, []} -> self()
            {_, name} -> name
          end

        # We do this to trick Dialyzer to not complain about non-local returns.
        case :erlang.phash2(1, 1) do
          0 ->
            raise "attempted to call GenServer #{inspect(proc)} but no handle_call/3 clause was provided"

          1 ->
            {:stop, {:bad_call, msg}, state}
        end
      end

      def __live_data_handle_info__(msg, state) do
        {:noreply, state}
      end

      def __live_data_handle_cast__(msg, state) do
        proc =
          case Process.info(self(), :registered_name) do
            {_, []} -> self()
            {_, name} -> name
          end

        # We do this to trick Dialyzer to not complain about non-local returns.
        case :erlang.phash2(1, 1) do
          0 ->
            raise "attempted to cast GenServer #{inspect(proc)} but no handle_cast/2 clause was provided"

          1 ->
            {:stop, {:bad_cast, msg}, state}
        end
      end
    end
  end

  defp wrap_handler(handler) do
    {k, f, a, _g, b} = handler

    quote do
      unquote(k)(
        unquote("__live_data_#{f}__" |> String.to_atom())(unquote_splicing(a)),
        unquote(b)
      )
    end
  end
end
