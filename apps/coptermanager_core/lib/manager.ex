defmodule CoptermanagerCore.Manager do
  use GenServer
  alias CoptermanagerCore.Protocol

  defmodule State do
    defstruct copters: []
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %State{}, opts)
  end

  defp exec_python(file, args) do
    case :os.type() do
      {:unix, _} -> Porcelain.exec(file, args)
      {:win32, _} ->
        case Application.get_env(:coptermanager_core, :python_win32_executable) do
          nil -> raise "please specify the path to python.exe"
          _ -> Porcelain.exec(Application.get_env(:coptermanager_core, :python_win32_executable), [file|args])
        end
      _ -> raise "Unknown operating system"
    end
  end

  defp send_serial_command(copterid, command, value) do
    serial_port = Application.get_env(:coptermanager_core, :serial_port)
    baudrate = Integer.to_string(Application.get_env(:coptermanager_core, :baudrate))
    args = [serial_port, baudrate, Integer.to_string(copterid), Integer.to_string(command), Integer.to_string(value)]
    %Porcelain.Result{out: stdout, err: stderr, status: exitcode} = exec_python(Path.join(__DIR__, "../../../external/sendserialcmd.py"), args)
    {stdout, stderr, exitcode}
  end

  defp get_error_message(stdout, stderr) do
    case stderr do
      nil -> stdout
      _ -> stderr
    end
  end

  def handle_call({:list}, _from, state) do
    {:reply, state.copters, state}
  end

  def handle_call({:bind, type}, _from, state) do
    cmdcode = Protocol.commands.copter_bind
    type = Protocol.types[type]

    case type do
      nil ->
        {:reply, {:error, "unknown type"}, state}

      _ ->
        {stdout, stderr, exitcode} = send_serial_command(0, cmdcode, type)
        
        cond do
          exitcode != 0 ->
            {:reply, {:error, get_error_message(stderr, stdout)}, state}

          stdout == Integer.to_string(Protocol.statuscodes.protocol_error) ->
            {:reply, {:error, "unknown type or all copter slots are in use"}, state}

          true ->
            {copterid, _} = Integer.parse(stdout)
            state = %State{copters: [copterid|state.copters]}
            {:reply, {:ok, copterid}, state}
        end
    end
  end

  def handle_call({:command, copterid, command, value}, _from, state) do
    commandcodes = Protocol.commands
    cmdcode = case command do
      "throttle" -> commandcodes.copter_throttle
      "rudder" -> commandcodes.copter_rudder
      "aileron" -> commandcodes.copter_aileron
      "elevator" -> commandcodes.copter_elevator
      "led" -> commandcodes.copter_led
      "flip" -> commandcodes.copter_flip
      "video" -> commandcodes.copter_video
      "land" -> commandcodes.copter_land
      _ -> nil
    end

    value = case command do
      "led" ->
        case value do
          "on" -> 0x01
          "off" -> 0x00
          _ -> nil
        end

      _ ->
        case Integer.parse(value) do
          :error -> nil
          {number, _} -> number
        end
    end

    cond do
      cmdcode == nil or value == nil ->
        {:reply, {:error, "unknown command or command value"}, state}

      true ->
        {stdout, stderr, exitcode} = send_serial_command(copterid, cmdcode, value)
        cond do
          exitcode != 0 ->
            {:reply, {:error, get_error_message(stderr, stdout)}, state}

          stdout == Integer.to_string(Protocol.statuscodes.protocol_error) ->
            {:reply, {:error, "command error"}, state}

          true ->
            {:reply, :ok, state}
        end
    end
  end
end
