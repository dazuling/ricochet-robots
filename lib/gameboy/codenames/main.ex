defmodule Gameboy.Codenames.Main do
  @moduledoc """
  Codenames game components, including settings, solving, game state, etc.

  Consider splitting new_game, new_board, and new_round.
  """

  use GenServer
  require Logger

  alias Gameboy.{Room, GameSupervisor}
  alias Gameboy.Codenames.{GameLogic}

  defstruct room_name: nil,
            password: "",
            board: nil,
            red_remaining: 0,
            blue_remaining: 0,
            current_team: 1, # 1 is red, 2 is blue
            game_over: false,
            winner: false,
            red_spymaster: nil,
            blue_spymaster: nil,
            ready_for_new_game: %{red: false, blue: false},
            clue: nil,
            remaining_guesses: 0,
            allow_overrides: true # ignore turn constraints
            

  @type t :: %{
          room_name: String.t(),
          password: String.t(),
          board: map,
          red_remaining: integer,
          blue_remaining: integer,
          current_team: 1 | 2,
          game_over: boolean,
          winner: 0 | 1 | 2,
          red_spymaster: String.t(),
          blue_spymaster: String.t(),
          ready_for_new_game: %{red: boolean, blue: boolean},
          clue: clue_t,
          remaining_guesses: integer,
          allow_overrides: boolean
        }
        

  @typedoc "Card: ..."
  @type card_t :: %{id: integer, word: String.t(), team: integer, uncovered: boolean}

  @typedoc "Wordlist: ..."
  @type wordlist_t :: %{ key: integer, name: String.t(), include: boolean, words: [String.t()]}

  @typedoc "Clue: ..."
  @type clue_t :: %{ word: String.t(), count: integer}


  def start_link(%{room_name: room_name} = opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(room_name))
  end

  @impl true
  @spec init(%{room_name: pid()}) :: {:ok, %__MODULE__{}}
  def init(%{room_name: room_name} = _opts) do
    Logger.info("[#{room_name}: Codenames] New game initialized.")
    state = new_round(%__MODULE__{room_name: room_name})

    {:ok, state}
  end

  @doc """
  Begin a new game. Broadcast new game information.
  """
  @spec new(room_name: String.t()) :: nil
  def new(room_name) do
    GameSupervisor.start_child(__MODULE__, %{room_name: room_name})
    # Room.system_chat(room_name, "A new game of Codenames is starting!")
  end

  def new_round(state) do
    {password, board, red_remaining, blue_remaining, current_team} = GameLogic.populate_board()
    
    new_state = %{ state | board: board,
                           password: password,
                           red_remaining: red_remaining,
                           blue_remaining: blue_remaining,
                           current_team: current_team,
                           game_over: false,
                           winner: 0,
                           red_spymaster: nil,
                           blue_spymaster: nil,
                           ready_for_new_game: %{red: false, blue: false},
                           clue: nil,
                           remaining_guesses: 0
                         }

    message = Poison.encode!(%{action: "new_game", content: password})
    GenServer.cast(via_tuple(state.room_name), {:broadcast_to_players, message})
    broadcast_board(new_state)
    broadcast_turn(new_state)

    new_state
  end


  @doc """
  Game functions that *have* to be sent out when a client joins, i.e. send out the board
  """
  @spec welcome_player(__MODULE__.t(), String.t()) :: :ok
  def welcome_player(state, _player_name) do
    broadcast_board(state)
    broadcast_turn(state)
    broadcast_spymasters(state)
    :ok
  end


  def handle_game_action(action, content, socket_state) do
    {:ok, _state} = fetch(socket_state.room_name)

    #Todo: only send poison response if necessary, else :noreply..
    case action do
      "submit_clue" -> 
        case GenServer.call(via_tuple(socket_state.room_name), {:submit_clue, socket_state.player_name, content}) do
          :ok -> Poison.encode!(%{content: false, action: "update_spymaster_modal"})
          {:error, err_msg} -> Poison.encode!(%{content: err_msg, action: "update_flash_msg"})
        end
      "uncover_card" -> 
        index = content["id"]
        override = Map.get(content, "override", false)
        case GenServer.call(via_tuple(socket_state.room_name), {:uncover_card, socket_state.player_name, index, override}) do
          :ok -> Poison.encode!(%{content: "ok", action: "update_board"})
          {:error, err_msg} -> Poison.encode!(%{content: err_msg, action: "update_flash_msg"})
        end
      "pass_turn" -> 
        case GenServer.call(via_tuple(socket_state.room_name), {:pass, socket_state.player_name}) do
          :ok -> :noreply
          {:error, err_msg} -> Poison.encode!(%{content: err_msg, action: "update_flash_msg"})
        end
      "set_spymaster" -> 
        case GenServer.call(via_tuple(socket_state.room_name), {:set_spymaster, socket_state.player_name, content}) do
          :ok -> Poison.encode!(%{content: "Waiting for opponent...", action: "update_message"})
          {:error, err_msg} -> Poison.encode!(%{content: err_msg, action: "update_flash_msg"})
        end
      "set_team" ->
        case GenServer.call(via_tuple(socket_state.room_name), {:set_team, socket_state.player_name, content}) do
          :ok ->
            {:ok, user_map} = Room.get_player(socket_state.room_name, socket_state.player_name)
            Poison.encode!(%{content: user_map, action: "update_user"})
          {:error, err_msg} -> Poison.encode!(%{content: err_msg, action: "update_flash_msg"})
        end
      "new_game" ->
        case GenServer.call(via_tuple(socket_state.room_name), {:new_game, socket_state.player_name}) do
          :ok -> Poison.encode!(%{content: "ok", action: "new_game"})
          {:error, err_msg} -> Poison.encode!(%{content: err_msg, action: "update_flash_msg"})
        end
      "uncover_all" ->
        case GenServer.call(via_tuple(socket_state.room_name), {:uncover_all, socket_state.player_name}) do
          :ok -> Poison.encode!(%{content: "ok", action: "uncover_all"})
          {:error, err_msg} -> Poison.encode!(%{content: err_msg, action: "update_flash_msg"})
        end
      _ -> :error_unknown_game_action
    end
  end


  # FETCH GAME: it has been registered under the room_name of the room in which it was started.
  @spec fetch(String.t()) :: {:ok, __MODULE__.t()} | :error_finding_game | :error_returning_state
  def fetch(room_name) do
    case GenServer.whereis(via_tuple(room_name)) do
      nil -> :error_finding_game
      _proc -> 
        case GenServer.call(via_tuple(room_name), :get_state) do
          {:ok, game} -> {:ok, game}
          _ -> :error_returning_state
        end
      end
  end

  def broadcast_board(state) do
    board = for %{id: i, word: w, uncovered: u, team: t} <- state.board, do: %{id: i, word: w, team: if u do t else nil end}
    content = %{password: state.password, board: board, red_remaining: state.red_remaining, blue_remaining: state.blue_remaining}
    message = Poison.encode!(%{action: "update_board", content: content})
    GenServer.cast(via_tuple(state.room_name), {:broadcast_to_players, message})
  end

  def broadcast_turn(state) do
    text = 
      cond do
        state.game_over and state.winner == 1 ->
          "Red has won the game!"

        state.game_over and state.winner == 2 ->
          "Blue has won the game!"

        state.game_over ->
          "Select New Game to play again."

        state.clue == nil -> 
          if state.current_team == 1 do
            "Waiting for red Spymaster"
          else
            "Waiting for blue Spymaster"
          end

        state.current_team == 1 ->
          "Clue: #{state.clue}"
      
        state.current_team == 2 ->
          "Clue: #{state.clue}"

        true ->
          "Error"
      end

    status_map = %{game_over: state.game_over, turn: state.current_team == 1, text: text, clue: state.clue, remaining_guesses: state.remaining_guesses}
    message = Poison.encode!(%{action: "update_status", content: status_map})
    GenServer.cast(via_tuple(state.room_name), {:broadcast_to_players, message})
  end
  
  def broadcast_spymasters(state) do
    message = Poison.encode!(%{action: "update_spymasters", content: [state.red_spymaster, state.blue_spymaster]})
    GenServer.cast(via_tuple(state.room_name), {:broadcast_to_players, message})
  end

  @impl true
  def handle_cast({:broadcast_to_players, message}, state) do
    Room.broadcast_to_players(message, state.room_name)
    {:noreply, state}
  end
  

  @impl true
  def handle_call({:submit_clue, player, content}, _from, state) do
    Logger.debug("SUBMIT CLUE BY #{inspect player}: #{inspect content}")

    cond do
      state.game_over ->
        {:reply, {:error, "Error: the game is already over."}, state}

      player != state.red_spymaster and player != state.blue_spymaster ->  
        {:reply, {:error, "You must be Spymaster to submit clues."}, state}
          
      state.clue != nil ->  
        {:reply, {:error, "A clue has already been sent."}, state}

      (state.current_team == 1 and player == state.red_spymaster) or (state.current_team == 2 and player == state.blue_spymaster) ->
        case content do
          %{"guesses" => g, "clue" => c} ->
            test_g = Integer.parse(g)
            cond do
              g == "infinity" ->
                state = %{state | clue: c, remaining_guesses: 9899}
                broadcast_turn(state)
                {:reply, :ok, state}

              test_g == :error ->
                {:reply, {:error, "Invalid number of guesses!"}, state}

              true ->
                {rg, _} = test_g
                remaining_guesses = if rg == 0 do 999 else rg + 1 end
                state = %{state | clue: c, remaining_guesses: remaining_guesses}
                broadcast_turn(state)
                {:reply, :ok, state}
              end
          _ -> 
            {:reply, {:error, "Invalid clue!"}, state}
        end

      true ->  
        {:reply, {:error, "It's not your turn!"}, state}

      end
  end


  @impl true
  def handle_call({:uncover_card, player_name, index, override}, _from, state) do
    case Room.fetch(state.room_name) do
      {:ok, room} -> 
        case Map.fetch(room.players, player_name) do
          {:ok, room_player} ->
            Logger.debug("UNCOVERING CARD: #{inspect player_name} on team #{inspect state.current_team} #{inspect index} #{inspect override}")
            
            if (override and state.allow_overrides) or state.game_over do
              case GameLogic.make_move(state.board, state.current_team, index) do
                :error_not_valid_move ->
                  {:reply, {:error, "Invalid attempt!"}, state}

                {continue_turn, assassin, red_remaining, blue_remaining, new_board} ->
                  
                  state = %{ state | board: new_board,
                                    red_remaining: red_remaining,
                                    blue_remaining: blue_remaining,
                                    remaining_guesses: state.remaining_guesses - 1 }
                  state =
                    cond do
                      assassin ->
                        %{ state | game_over: true,
                                  winner: 3 - state.current_team,
                                  current_team: 3 - state.current_team }
                      red_remaining == 0 ->
                        %{ state | game_over: true,
                                  winner: 1 }
                      blue_remaining == 0 ->
                        %{ state | game_over: true,
                                    winner: 2 }
                      assassin ->
                        %{ state | game_over: true,
                                  winner: 3 - state.current_team }
                      not continue_turn ->
                        %{ state | clue: nil,
                                  remaining_guesses: 0,
                                  current_team: 3 - state.current_team }
                      true ->
                        state
                    end
                    
                  broadcast_board(state)
                  broadcast_turn(state)
                  broadcast_spymasters(state)
                  {:reply, :ok, state}
              end
            else
              cond do
                room_player.team < 1 or room_player.team > 2 ->
                  {:reply, {:error, "You are not on a team!"}, state}

                state.current_team != room_player.team ->
                  {:reply, {:error, "It's not your turn!"}, state}

                state.clue == nil ->
                  {:reply, {:error, "Awaiting clue from your Spymaster."}, state}

                player_name == state.red_spymaster or player_name == state.blue_spymaster ->
                  {:reply, {:error, "Spymasters don't uncover cards!"}, state}

                true ->
                  case GameLogic.make_move(state.board, state.current_team, index) do
                    :error_not_valid_move ->
                      {:reply, {:error, "Invalid attempt!"}, state}

                    {continue_turn, assassin, red_remaining, blue_remaining, new_board} ->
                      
                      state = %{ state | board: new_board,
                                        red_remaining: red_remaining,
                                        blue_remaining: blue_remaining,
                                        remaining_guesses: state.remaining_guesses - 1 }

                      state =
                        cond do
                          assassin ->
                            %{ state | game_over: true,
                                      winner: 3 - state.current_team }
                                      
                          red_remaining == 0 ->
                            %{ state | game_over: true,
                                      winner: 1 }
                          
                          blue_remaining == 0 ->
                            %{ state | game_over: true,
                                        winner: 2 }
                                      
                          assassin ->
                            %{ state | game_over: true,
                                      winner: 3 - state.current_team }

                          not continue_turn ->
                            %{ state | clue: nil,
                                      remaining_guesses: 0,
                                      current_team: 3 - state.current_team }

                          true ->
                            state
                        end
                        
                      broadcast_board(state)
                      broadcast_turn(state)
                      broadcast_spymasters(state)
                      {:reply, :ok, state}
                  end
              end
            end
            
          :error ->
            {:reply, {:error, "Error finding #{inspect player_name} in #{inspect state.room_name}"}, state}
        end



      _ ->
        Logger.debug("Could not find room #{inspect state.room_name}")
        {:reply, {:error, "Unknown room"}, state}
    end

  end

  
  
  @impl true
  def handle_call({:pass, player_name}, _from, state) do
    
    case Room.fetch(state.room_name) do
      {:ok, room} -> 
        case Map.fetch(room.players, player_name) do
          {:ok, room_player} ->
            Logger.debug("PASS BY #{inspect player_name}")

            cond do
              room_player.team != state.current_team ->  
                {:reply, {:error, "It's not your turn."}, state}
                
              state.clue == nil ->  
                {:reply, {:error, "It's not time to pass."}, state}
              
              player_name == state.red_spymaster or player_name == state.blue_spymaster ->  
                {:reply, {:error, "Spymasters can't pass."}, state}

              true ->
                new_state = %{state | current_team: 3-state.current_team, clue: nil, remaining_guesses: 0}
                
                broadcast_turn(new_state)
                broadcast_spymasters(state)
                                    
                {:reply, :ok, new_state}
            end
            
            :error ->
              {:reply, {:error, "Error finding #{inspect player_name} in #{inspect state.room_name}"}, state}
          end
        _ ->
          Logger.debug("Could not find room #{inspect state.room_name}")
          {:reply, {:error, "Unknown room"}, state}
      end

  end

  
  @impl true
  def handle_call({:set_team, player, teamid}, _from, state) do
    Logger.debug("SETTING TEAM #{inspect player} #{inspect teamid}")

    case Room.set_team(state.room_name, player, teamid) do
      :ok ->   
        broadcast_turn(state)
        Room.broadcast_scoreboard(state.room_name)
        {:reply, :ok, state}
      _ ->
        Room.broadcast_scoreboard(state.room_name)
        {:reply, {:error, "Unable to set team"}, state}
    end
  end

  # ignores instructions and attempts to make player the spymaster for their current team.
  @impl true
  def handle_call({:set_spymaster, player, _team}, _from, state) do

    Logger.debug("SET SPYMASTER BY #{inspect player}")

    case Room.fetch(state.room_name) do
      {:ok, room} -> 
        case Map.fetch(room.players, player) do
          {:ok, room_player} ->
          
            cond do
              room_player.team == 1 ->
                # if state.red_spymaster do
                #  {:reply, {:error, "There is already a red Spymaster."}, state}
                # else
                  new_state = %{state | red_spymaster: player}
                  broadcast_spymasters(new_state)
                  {:reply, :ok, new_state}
                # end
              
              room_player.team == 2 -> 
                new_state = %{state | blue_spymaster: player}
                broadcast_spymasters(new_state)
                {:reply, :ok, new_state}
              
              true ->
                {:reply, {:error, "Join a team before becoming Spymaster."}, state}
            end

        _ ->
          {:reply, {:error, "Unable to find \"#{inspect player}\". Please try reconnecting."}, state}
      end

      _ -> 
        {:reply, {:error, "Unable to find your game room."}, state}
    end
  end

    
  
  @impl true
  def handle_call({:new_game, player}, _from, state) do

    Logger.debug("NEW GAME INIT BY #{inspect player}")
    ready = %{red: true, blue: true}
    
    if ready == %{red: true, blue: true} do
      new_game = new_round(state) 
      {:reply, :ok, new_game}
    else
      {:reply, :ok, %{state | ready_for_new_game: ready}}
    end
        
  end

  
  @impl true
  def handle_call({:uncover_all, player}, _from, state) do

    Logger.debug("UNCOVER ALL INIT BY #{inspect player}")

    cond do
      not state.game_over ->  
        {:reply, {:error, "The game isn't over yet!."}, state}

      true ->
        ready =
          cond do
            player == state.red ->
              %{state.ready_for_new_game | red: true}
            
            player == state.blue ->
              %{state.ready_for_new_game | blue: true}
          end
        
        if ready == %{red: true, blue: true} do
          new_game = new_round(state) 
          {:reply, :ok, new_game}
        else
          {:reply, :ok, %{state | ready_for_new_game: ready}}
        end
        
    end
  end

    


  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  defp via_tuple(room_name) do
    {:via, Registry, {Registry.GameRegistry, room_name}}
  end
  
end
