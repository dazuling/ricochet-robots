defmodule RicochetRobots.Room do
  use GenServer

  defstruct name: nil,
            game: nil,
            players: [],
            chat: []

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(name) do
    {:ok, %__MODULE__{name: name}}
  end

  def create_game(name) do
    GenServer.cast(__MODULE__, {:create_game, name})
  end

  def add_player(player) do
    GenServer.cast(__MODULE__, {:add_player, player})
  end

  def send_message(player, message) do
    GenServer.cast(__MODULE__, {:send_message, {player, message}})
  end

  def log_to_chat(message) do
    GenServer.cast(__MODULE__, {:log_to_chat, message})
  end

  @impl true
  def handle_cast({:create_game}, state) do
    game = GameSupervisor.start_link()
    {:ok, Map.put(state, :game, game)}
  end

  @impl true
  def handle_cast({:add_player, player}, state) do
    state = %{state | players: [player | state.players]}
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_message, {player, message}}, state) do
    state = %{state | chat: ["<#{player}> #{message}" | state.chat]}
    {:ok, state}
  end

  @impl true
  def handle_cast({:log_to_chat, message}, state) do
    state = %{state | chat: [message | state.chat]}
    {:ok, state}
  end
end