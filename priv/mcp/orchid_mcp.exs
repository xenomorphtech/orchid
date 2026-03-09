#!/usr/bin/env elixir
# Orchid MCP Server — exposes Orchid tools to Claude CLI via MCP protocol (stdio JSON-RPC)
#
# Usage: elixir --name mcp-<PID>@127.0.0.1 --cookie <cookie> priv/mcp/orchid_mcp.exs <project_id> [agent_id]

defmodule OrchidMCP do
  @node :"orchid@127.0.0.1"
  @log_file Path.expand("priv/data/mcp.log", __DIR__ |> Path.join("../.."))
  @template_scoped_tools ~w(project_list project_create)

  def main(args) do
    project_id = Enum.at(args, 0)
    agent_id = Enum.at(args, 1)

    unless project_id do
      log("ERROR: no project_id provided")
      System.halt(1)
    end

    log("starting, project=#{project_id}, agent=#{agent_id}")

    unless Node.connect(@node) do
      log("ERROR: cannot connect to #{@node}")
      System.halt(1)
    end

    log("connected to #{@node}")

    state = %{project_id: project_id, agent_id: agent_id}
    loop(state)
  end

  defp log(msg) do
    ts = DateTime.utc_now() |> DateTime.to_string()
    line = "[#{ts}] MCP: #{msg}\n"
    File.write!(@log_file, line, [:append])
    IO.puts(:stderr, "OrchidMCP: #{msg}")
  end

  # Use built-in JSON module (Elixir 1.18+) instead of Jason
  defp json_decode(str), do: JSON.decode(str)
  defp json_encode!(term), do: JSON.encode!(term)

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        log("EOF on stdin, exiting")
        :ok

      {:error, reason} ->
        log("stdin error: #{inspect(reason)}, exiting")
        :ok

      line ->
        line = String.trim(line)

        if line != "" do
          log("recv: #{String.slice(line, 0, 300)}")

          try do
            case json_decode(line) do
              {:ok, msg} ->
                response = handle_message(msg, state)

                if response do
                  encoded = json_encode!(response)
                  log("send: #{String.slice(encoded, 0, 300)}")
                  IO.write(:stdio, encoded <> "\n")
                else
                  log("send: (nil, no response)")
                end

              {:error, err} ->
                log("JSON decode error: #{inspect(err)}")
            end
          rescue
            e ->
              log(
                "CRASH: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
              )
          end
        end

        loop(state)
    end
  end

  defp handle_message(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = msg, state) do
    params = (msg["params"] || %{}) |> Map.put_new("request_id", id)
    result = handle_method(method, params, state)

    case result do
      {:ok, r} ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => r}

      {:error, code, message} ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
    end
  end

  # Notifications (no id)
  defp handle_message(%{"jsonrpc" => "2.0", "method" => "notifications/" <> _}, _state), do: nil
  defp handle_message(_, _state), do: nil

  defp handle_method("initialize", _params, _state) do
    {:ok,
     %{
       "protocolVersion" => "2024-11-05",
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "orchid-mcp", "version" => "1.0.0"}
     }}
  end

  defp handle_method("tools/list", _params, state) do
    {:ok, %{"tools" => tools_for_state(state)}}
  end

  defp handle_method("tools/call", %{"name" => name, "arguments" => args} = params, state) do
    if not tool_allowed?(state, name) do
      {:ok,
       %{
         "content" => [
           %{"type" => "text", "text" => "Error: tool not allowed for this agent: #{name}"}
         ],
         "isError" => true
       }}
    else
      started = System.monotonic_time(:millisecond)
      request_id = Map.get(params, "request_id")
      log("TOOL CALL: #{name}(#{inspect(args) |> String.slice(0, 300)})")
      result = execute_tool(name, args, state)

      case result do
        {:ok, text} ->
          emit_call_event(state, name, request_id, "ok", started)
          log("TOOL OK: #{name} -> #{String.slice(to_string(text), 0, 200)}")

          {:ok,
           %{"content" => [%{"type" => "text", "text" => to_string(text)}], "isError" => false}}

        {:error, err} ->
          emit_call_event(state, name, request_id, "error", started)
          log("TOOL ERROR: #{name} -> #{inspect(err) |> String.slice(0, 200)}")

          {:ok,
           %{
             "content" => [%{"type" => "text", "text" => "Error: #{inspect(err)}"}],
             "isError" => true
           }}
      end
    end
  end

  defp handle_method(_method, _params, _state) do
    {:error, -32601, "Method not found"}
  end

  defp emit_call_event(state, tool, request_id, outcome, started_ms) do
    duration_ms = max(System.monotonic_time(:millisecond) - started_ms, 0)

    event = %{
      project_id: state.project_id,
      agent_id: state.agent_id,
      tool: tool,
      request_id: request_id,
      outcome: outcome,
      duration_ms: duration_ms
    }

    :rpc.call(@node, Orchid.McpEvents, :record_call, [event])
    :ok
  end

  # Tool definitions — use string keys for JSON serialization
  defp tools do
    [
      %{
        "name" => "goal_list",
        "description" => "List all goals for the current project",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "goal_read",
        "description" => "Read a goal's full details",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Goal ID or name"}
          }
        }
      },
      %{
        "name" => "goal_create",
        "description" => "Create a new goal",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Short goal name"},
            "description" => %{
              "type" => "string",
              "description" => "Detailed description — this is the work order"
            },
            "depends_on" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Goal IDs/names this depends on"
            },
            "parent_goal_id" => %{"type" => "string", "description" => "Parent goal ID"}
          }
        }
      },
      %{
        "name" => "subgoal_create",
        "description" => "Create a subgoal under a parent goal (defaults to your assigned goal)",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Short subgoal name"},
            "description" => %{
              "type" => "string",
              "description" => "Detailed subgoal description"
            },
            "parent_goal_id" => %{
              "type" => "string",
              "description" => "Parent goal ID/name (optional; defaults to your assigned goal)"
            },
            "depends_on" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Goal IDs/names this subgoal depends on"
            }
          },
          "required" => ["name"]
        }
      },
      %{
        "name" => "subgoal_list",
        "description" => "List subgoals under a parent goal (defaults to your assigned goal)",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "parent_goal_id" => %{
              "type" => "string",
              "description" => "Parent goal ID/name (optional; defaults to your assigned goal)"
            }
          }
        }
      },
      %{
        "name" => "goal_update",
        "description" => "Update a goal's status or report",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string", "description" => "Goal ID or name"},
            "status" => %{"type" => "string", "description" => "New status: pending or completed"},
            "report" => %{
              "type" => "string",
              "description" => "Progress report or completion summary"
            }
          }
        }
      },
      %{
        "name" => "task_report",
        "description" => "Report task outcome with summary/error and optional completion",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "goal_id" => %{
              "type" => "string",
              "description" => "Goal ID or name (optional; defaults to assigned goal)"
            },
            "outcome" => %{
              "type" => "string",
              "description" => "success | failure | blocked | in_progress"
            },
            "summary" => %{"type" => "string", "description" => "Short status summary"},
            "report" => %{"type" => "string", "description" => "Detailed report text"},
            "error" => %{"type" => "string", "description" => "Error details for failure/blocked"},
            "mark_completed" => %{
              "type" => "boolean",
              "description" => "For success, mark goal completed (default true)"
            }
          }
        }
      },
      %{
        "name" => "agent_spawn",
        "description" => "Spawn an agent from a template and assign it a goal",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "template" => %{
              "type" => "string",
              "description" =>
                "Template name (Coder, Codex Coder, Reverse Engineer, Shell Operator, Explorer)"
            },
            "goal_id" => %{"type" => "string", "description" => "Goal ID or name to assign"},
            "message" => %{
              "type" => "string",
              "description" => "Initial message (only if no goal_id)"
            }
          }
        }
      },
      %{
        "name" => "project_list",
        "description" => "List all Orchid projects with name and files location",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "project_create",
        "description" => "Create a new Orchid project",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Project name"}
          },
          "required" => ["name"]
        }
      },
      %{
        "name" => "active_agents",
        "description" => "List active agents with type and assigned task",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "wait",
        "description" => "Wait up to N seconds for notifications from spawned agents",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "seconds" => %{"type" => "integer", "description" => "Max seconds to wait (1-300)"},
            "status_msg" => %{
              "type" => "string",
              "description" => "Short status message for UI (e.g. waiting for extraction results)"
            }
          }
        }
      },
      %{
        "name" => "list",
        "description" => "List files in the workspace",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Path to list (default: /workspace)"}
          }
        }
      },
      %{
        "name" => "read",
        "description" => "Read a file from the workspace",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "File path"}
          }
        }
      },
      %{
        "name" => "grep",
        "description" => "Search file contents with a regex pattern",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "pattern" => %{"type" => "string", "description" => "Regex pattern"},
            "path" => %{
              "type" => "string",
              "description" => "Path to search (default: /workspace)"
            },
            "glob" => %{"type" => "string", "description" => "File glob filter"}
          }
        }
      },
      %{
        "name" => "ping",
        "description" =>
          "Keepalive — call this every few minutes during long waits to prevent timeout. Returns 'pong'.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  # Tool execution — calls Orchid via RPC
  defp execute_tool("goal_list", _args, state) do
    goals = :rpc.call(@node, Orchid.Object, :list_goals_for_project, [state.project_id])

    if is_list(goals) do
      text =
        Enum.map_join(goals, "\n", fn g ->
          status = g.metadata[:status] || :pending
          deps = g.metadata[:depends_on] || []
          agent = g.metadata[:agent_id]
          dep_str = if deps == [], do: "", else: " depends_on=[#{Enum.join(deps, ", ")}]"
          agent_str = if agent, do: " agent=#{agent}", else: ""
          "[#{status}] #{g.name} [#{g.id}]#{dep_str}#{agent_str}"
        end)

      {:ok, text}
    else
      {:error, "RPC failed: #{inspect(goals)}"}
    end
  end

  defp execute_tool("goal_read", %{"id" => id}, state) do
    goal = resolve_goal(id, state.project_id)

    case goal do
      nil ->
        {:error, "Goal not found: #{id}"}

      g ->
        text = """
        Name: #{g.name}
        ID: #{g.id}
        Status: #{g.metadata[:status] || :pending}
        Agent: #{g.metadata[:agent_id] || "none"}
        Dependencies: #{inspect(g.metadata[:depends_on] || [])}
        Parent: #{g.metadata[:parent_goal_id] || "root"}
        Report: #{g.metadata[:report] || "none"}

        Description:
        #{g.content}
        """

        {:ok, String.trim(text)}
    end
  end

  defp execute_tool("goal_create", args, state) do
    name = args["name"] || "Unnamed"
    desc = args["description"] || ""
    parent = args["parent_goal_id"]

    # Resolve parent — default to agent's assigned goal
    parent_id =
      if parent do
        case resolve_goal(parent, state.project_id) do
          nil -> nil
          g -> g.id
        end
      else
        # Auto-set to creating agent's assigned goal
        if state.agent_id do
          :rpc.call(@node, Orchid.Object, :list_goals_for_project, [state.project_id])
          |> Enum.find(fn g -> g.metadata[:agent_id] == state.agent_id end)
          |> case do
            nil -> nil
            g -> g.id
          end
        end
      end

    opts = if parent_id, do: [parent_goal_id: parent_id], else: []

    case :rpc.call(@node, Orchid.Goals, :create, [name, desc, state.project_id, opts]) do
      {:ok, goal} ->
        # Resolve depends_on
        if args["depends_on"] && args["depends_on"] != [] do
          dep_ids =
            Enum.map(args["depends_on"], fn ref ->
              case resolve_goal(ref, state.project_id) do
                # keep as-is if not found
                nil -> ref
                g -> g.id
              end
            end)

          :rpc.call(@node, Orchid.Object, :update_metadata, [goal.id, %{depends_on: dep_ids}])
        end

        {:ok, "Created goal: #{goal.name} [#{goal.id}]"}

      error ->
        {:error, "Failed: #{inspect(error)}"}
    end
  end

  defp execute_tool("goal_update", %{"id" => id} = args, state) do
    case resolve_goal(id, state.project_id) do
      nil ->
        {:error, "Goal not found: #{id}"}

      g ->
        if args["status"] do
          status_atom = String.to_existing_atom(args["status"])
          :rpc.call(@node, Orchid.Goals, :set_status, [g.id, status_atom])
        end

        if args["report"] do
          :rpc.call(@node, Orchid.Object, :update_metadata, [g.id, %{report: args["report"]}])
        end

        {:ok, "Updated goal #{g.name}#{if args["status"], do: " to #{args["status"]}", else: ""}"}
    end
  end

  defp execute_tool("subgoal_create", %{"name" => name} = args, state) do
    parent =
      cond do
        is_binary(args["parent_goal_id"]) and args["parent_goal_id"] != "" ->
          resolve_goal(args["parent_goal_id"], state.project_id)

        true ->
          assigned_goal(state)
      end

    if is_nil(parent) do
      {:error,
       "No parent goal found for subgoal_create (set parent_goal_id or assign a goal first)"}
    else
      desc = args["description"] || ""
      opts = [parent_goal_id: parent.id]

      case :rpc.call(@node, Orchid.Goals, :create, [name, desc, state.project_id, opts]) do
        {:ok, goal} ->
          if args["depends_on"] && args["depends_on"] != [] do
            dep_ids =
              Enum.map(args["depends_on"], fn ref ->
                case resolve_goal(ref, state.project_id) do
                  nil -> ref
                  g -> g.id
                end
              end)

            :rpc.call(@node, Orchid.Object, :update_metadata, [goal.id, %{depends_on: dep_ids}])
          end

          {:ok,
           "Created subgoal: #{goal.name} [#{goal.id}] under parent #{parent.name} [#{parent.id}]"}

        error ->
          {:error, "Failed creating subgoal: #{inspect(error)}"}
      end
    end
  end

  defp execute_tool("subgoal_list", args, state) do
    parent =
      cond do
        is_binary(args["parent_goal_id"]) and args["parent_goal_id"] != "" ->
          resolve_goal(args["parent_goal_id"], state.project_id)

        true ->
          assigned_goal(state)
      end

    if is_nil(parent) do
      {:error,
       "No parent goal found for subgoal_list (set parent_goal_id or assign a goal first)"}
    else
      goals = :rpc.call(@node, Orchid.Object, :list_goals_for_project, [state.project_id])

      if is_list(goals) do
        children =
          Enum.filter(goals, fn g ->
            g.metadata[:parent_goal_id] == parent.id
          end)

        text =
          case children do
            [] ->
              "No subgoals under #{parent.name} [#{parent.id}]"

            list ->
              lines =
                Enum.map(list, fn g ->
                  status = g.metadata[:status] || :pending
                  deps = g.metadata[:depends_on] || []
                  dep_str = if deps == [], do: "", else: " deps=[#{Enum.join(deps, ", ")}]"
                  "[#{status}] #{g.name} [#{g.id}]#{dep_str}"
                end)

              "Subgoals for #{parent.name} [#{parent.id}]:\n" <> Enum.join(lines, "\n")
          end

        {:ok, text}
      else
        {:error, "RPC failed listing goals: #{inspect(goals)}"}
      end
    end
  end

  defp execute_tool("task_report", args, state) do
    outcome = to_string(args["outcome"] || "")
    summary = to_string(args["summary"] || "")

    if outcome == "" or summary == "" do
      {:error, "task_report requires outcome and summary"}
    else
      goal =
        cond do
          is_binary(args["goal_id"]) and args["goal_id"] != "" ->
            resolve_goal(args["goal_id"], state.project_id)

          is_binary(state.agent_id) ->
            :rpc.call(@node, Orchid.Object, :list_goals_for_project, [state.project_id])
            |> Enum.find(fn g ->
              g.metadata[:agent_id] == state.agent_id and g.metadata[:status] != :completed
            end)

          true ->
            nil
        end

      if is_nil(goal) do
        {:error, "No target goal found for task_report"}
      else
        if outcome in ["failure", "blocked"] and
             (is_nil(args["error"]) or String.trim(to_string(args["error"])) == "") do
          {:error, "error is required when outcome is failure or blocked"}
        else
          pending_children = pending_child_goals(goal.id, state.project_id)

          if outcome == "success" and Map.get(args, "mark_completed", true) and
               pending_children != [] do
            names = Enum.map_join(pending_children, ", ", fn g -> "#{g.name} [#{g.id}]" end)
            {:error, "Cannot mark goal completed while subgoals are pending: #{names}"}
          else
            report = to_string(args["report"] || summary)
            error_text = to_string(args["error"] || "")

            :rpc.call(@node, Orchid.Object, :update_metadata, [
              goal.id,
              %{
                completion_summary: summary,
                report: report,
                last_error:
                  if(outcome in ["failure", "blocked"],
                    do: if(String.trim(error_text) == "", do: summary, else: error_text),
                    else: nil
                  ),
                task_outcome: outcome,
                reported_by_tool: true,
                reported_at: DateTime.utc_now()
              }
            ])

            cond do
              outcome == "success" and Map.get(args, "mark_completed", true) ->
                :rpc.call(@node, Orchid.Goals, :set_status, [goal.id, :completed])

              true ->
                :rpc.call(@node, Orchid.Goals, :set_status, [goal.id, :pending])
            end

            {:ok, "Reported #{outcome} for goal #{goal.name} [#{goal.id}]"}
          end
        end
      end
    end
  end

  defp pending_child_goals(parent_goal_id, project_id) do
    goals = :rpc.call(@node, Orchid.Object, :list_goals_for_project, [project_id])

    if is_list(goals) do
      Enum.filter(goals, fn g ->
        g.metadata[:parent_goal_id] == parent_goal_id and g.metadata[:status] != :completed
      end)
    else
      []
    end
  end

  defp execute_tool("agent_spawn", %{"template" => _template} = args, state) do
    # Call Orchid's agent_spawn tool
    ctx = %{agent_state: agent_spawn_context(state)}

    case :rpc.call(@node, Orchid.Tools.AgentSpawn, :execute, [args, ctx]) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      {:badrpc, reason} -> {:error, "agent_spawn RPC failed: #{inspect(reason)}"}
      other -> {:error, "agent_spawn returned unexpected result: #{inspect(other)}"}
    end
  end

  defp execute_tool("project_list", _args, _state) do
    projects = :rpc.call(@node, Orchid.Object, :list_projects, [])

    if is_list(projects) do
      text =
        case projects do
          [] ->
            "No projects found."

          _ ->
            Enum.map_join(projects, "\n\n", fn p ->
              status = p.metadata[:status] || :active
              files_path = :rpc.call(@node, Orchid.Project, :files_path, [p.id])
              "[#{status}] #{p.name} (#{p.id})\nfiles: #{files_path}"
            end)
        end

      {:ok, text}
    else
      {:error, "RPC failed listing projects: #{inspect(projects)}"}
    end
  end

  defp execute_tool("project_create", %{"name" => raw_name}, _state) do
    name = to_string(raw_name) |> String.trim()

    if name == "" do
      {:error, "project_create requires a non-empty name"}
    else
      case :rpc.call(@node, Orchid.Projects, :create, [name]) do
        {:ok, project} ->
          files_path = :rpc.call(@node, Orchid.Project, :files_path, [project.id])
          {:ok, "Created project: #{project.name} (#{project.id})\nfiles: #{files_path}"}

        error ->
          {:error, "Failed to create project: #{inspect(error)}"}
      end
    end
  end

  defp execute_tool("active_agents", _args, state) do
    agents = :rpc.call(@node, Orchid.Agent, :list, [])
    goals = :rpc.call(@node, Orchid.Object, :list_goals_for_project, [state.project_id])

    cond do
      !is_list(agents) ->
        {:error, "RPC failed listing agents: #{inspect(agents)}"}

      !is_list(goals) ->
        {:error, "RPC failed listing goals: #{inspect(goals)}"}

      true ->
        agents_for_project =
          Enum.filter(agents, fn id ->
            case :rpc.call(@node, Orchid.Agent, :get_state, [id]) do
              {:ok, s} -> s.project_id == state.project_id
              _ -> false
            end
          end)

        text =
          case agents_for_project do
            [] ->
              "No active agents for this project."

            ids ->
              lines =
                Enum.map(ids, fn id ->
                  case :rpc.call(@node, Orchid.Agent, :get_state, [id]) do
                    {:ok, s} ->
                      type =
                        cond do
                          s.config[:use_orchid_tools] -> "Orchestrator"
                          s.config[:template_id] -> template_name(s.config[:template_id])
                          true -> "Unknown"
                        end

                      task =
                        case Enum.find(goals, fn g -> g.metadata[:agent_id] == id end) do
                          nil -> "none"
                          g -> "#{g.name} [#{g.id}]"
                        end

                      "#{id} | type=#{type} | task=#{task}"

                    _ ->
                      "#{id} | type=unknown | task=unknown"
                  end
                end)

              Enum.join(lines, "\n")
          end

        {:ok, text}
    end
  end

  defp execute_tool("wait", args, state) do
    unless state.agent_id do
      {:ok, "No agent_id — cannot wait for notifications"}
    else
      status_msg =
        case args["status_msg"] do
          msg when is_binary(msg) ->
            msg
            |> String.trim()
            |> String.slice(0, 120)

          _ ->
            nil
        end

      if status_msg && status_msg != "" do
        :rpc.call(@node, Orchid.Agent, :remember, [state.agent_id, "wait_status", status_msg])
      end

      # Cap at 120s per wait call to avoid blocking too long
      seconds = min(max(args["seconds"] || 60, 1), 120)
      deadline = System.monotonic_time(:second) + seconds
      wait_loop(state.agent_id, deadline)
    end
  end

  defp execute_tool("list", args, state) do
    path = args["path"] || "/workspace"

    case :rpc.call(@node, Orchid.Sandbox, :list_files, [state.project_id, path]) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool("read", %{"path" => path}, state) do
    case :rpc.call(@node, Orchid.Sandbox, :read_file, [state.project_id, path]) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool("grep", %{"pattern" => pattern} = args, state) do
    path = args["path"] || "/workspace"
    opts = if args["glob"], do: [glob: args["glob"]], else: []

    case :rpc.call(@node, Orchid.Sandbox, :grep_files, [state.project_id, pattern, path, opts]) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_tool("ping", _args, _state) do
    {:ok, "pong"}
  end

  defp execute_tool(name, _args, _state) do
    {:error, "Unknown tool: #{name}"}
  end

  # Helpers
  defp resolve_goal(ref, project_id) do
    goals = :rpc.call(@node, Orchid.Object, :list_goals_for_project, [project_id])

    if is_list(goals) do
      Enum.find(goals, fn g -> g.id == ref end) ||
        Enum.find(goals, fn g -> String.downcase(g.name) == String.downcase(ref) end)
    end
  end

  defp assigned_goal(state) do
    if is_binary(state.agent_id) and state.agent_id != "" do
      goals = :rpc.call(@node, Orchid.Object, :list_goals_for_project, [state.project_id])

      if is_list(goals) do
        Enum.find(goals, fn g ->
          g.metadata[:agent_id] == state.agent_id and g.metadata[:status] != :completed
        end)
      end
    end
  end

  defp template_name(template_id) do
    case :rpc.call(@node, Orchid.Object, :get, [template_id]) do
      {:ok, t} -> t.name
      _ -> template_id
    end
  end

  defp tools_for_state(state) do
    all = tools()

    case allowed_tools_for_agent(state.agent_id) do
      nil ->
        Enum.reject(all, fn t -> t["name"] in @template_scoped_tools end)

      allowed when is_list(allowed) ->
        allowed_set = MapSet.new(Enum.map(allowed, &to_string/1))
        Enum.filter(all, fn t -> MapSet.member?(allowed_set, t["name"]) end)
    end
  end

  defp tool_allowed?(state, tool_name) do
    case allowed_tools_for_agent(state.agent_id) do
      nil -> to_string(tool_name) not in @template_scoped_tools
      allowed when is_list(allowed) -> to_string(tool_name) in Enum.map(allowed, &to_string/1)
      _ -> true
    end
  end

  defp allowed_tools_for_agent(nil), do: nil

  defp allowed_tools_for_agent(agent_id) do
    case :rpc.call(@node, Orchid.Agent, :get_state, [agent_id]) do
      {:ok, s} -> s.config[:allowed_tools]
      _ -> nil
    end
  end

  defp agent_spawn_context(%{agent_id: agent_id, project_id: project_id})
       when is_binary(agent_id) do
    case :rpc.call(@node, Orchid.Agent, :get_state, [agent_id]) do
      {:ok, agent_state} ->
        agent_state

      _ ->
        %{id: agent_id, project_id: project_id, execution_mode: :vm}
    end
  end

  defp agent_spawn_context(%{project_id: project_id}) do
    %{id: nil, project_id: project_id, execution_mode: :vm}
  end

  defp wait_loop(agent_id, deadline) do
    case :rpc.call(@node, Orchid.Agent, :drain_notifications, [agent_id]) do
      {:ok, []} ->
        if System.monotonic_time(:second) < deadline do
          Process.sleep(2_000)
          wait_loop(agent_id, deadline)
        else
          {:ok, "No notifications received within timeout."}
        end

      {:ok, notifications} ->
        text = Enum.join(notifications, "\n\n---\n\n")
        {:ok, "Received #{length(notifications)} notification(s):\n\n#{text}"}
    end
  end
end

# Parse args from System.argv()
OrchidMCP.main(System.argv())
