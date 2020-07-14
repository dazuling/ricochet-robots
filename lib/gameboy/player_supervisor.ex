defmodule Gameboy.PlayerSupervisor do
  @moduledoc false

  use Supervisor
  require Logger

  def start_link(opts) do
    Logger.debug("Starting PlayerSupervisor link for player \"#{inspect(opts)}\"")
    Supervisor.start_link(__MODULE__, opts)
  end

  #
  @impl true
  def init(opts) do

    Logger.debug("Got to PlayerSupervisor INIT with opts=#{inspect(opts)}")

    children = [
      %{
        id: Gameboy.Player,
        start: {Gameboy.Player, :start_link, [opts]}
      }
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
end