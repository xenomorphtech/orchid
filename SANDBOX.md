# Sandbox Architecture — Project Folders, Layered FS, Container Isolation

## Overview

Each agent can now run inside an isolated Podman container with OverlayFS, so agents on the same project share read-only access to project files but writes are private per-agent.

```
Project (id: "abc")
  folder: priv/data/projects/abc/files/
    |
    +-- Agent A
    |   upper: priv/data/sandboxes/A/upper/
    |   container: orchid-A  (/workspace = overlay merge)
    |
    +-- Agent B
        upper: priv/data/sandboxes/B/upper/
        container: orchid-B  (/workspace = overlay merge)
```

Agents without a `project_id` have no sandbox — tools run directly on the host (unchanged behavior).

---

## New Files

### `lib/orchid/project.ex`
Project directory management. Pure functions, no GenServer.

- `data_dir/0` — reads `:orchid, :data_dir` config (default `"priv/data"`)
- `files_path(project_id)` — `<data_dir>/projects/<id>/files`
- `ensure_dir(project_id)` — `mkdir_p!`, returns `{:ok, path}`
- `delete_dir(project_id)` — `rm_rf` the project dir

### `lib/orchid/sandbox/overlay.ex`
Application-level union FS fallback, used when the container can't do a real overlay mount.

- `union_read(rel_path, upper, lower)` — checks upper first, then lower
- `union_write(rel_path, content, upper)` — always writes to upper, creates parent dirs
- `union_list(rel_path, upper, lower)` — merges directory listings, upper wins
- `union_grep(pattern, rel_path, upper, lower, opts)` — greps both layers, deduplicates

### `lib/orchid/sandbox.ex`
GenServer, one per agent. Registered as `{:sandbox, agent_id}` in `Orchid.Registry`.

**State struct:**
```elixir
defstruct [:agent_id, :project_id, :container_name, :lower_path, :upper_path,
           :work_path, :merged_path, :overlay_method, :image, :status]
```

**Client API:**
- `start_link({agent_id, project_id})`
- `exec(agent_id, command, opts)` — `podman exec -w /workspace`
- `read_file/write_file/edit_file/list_files/grep_files` — routed through container or union fallback
- `reset(agent_id)` — destroys and recreates the container (upper data preserved)
- `stop(agent_id)` — destroys container, stops GenServer
- `status(agent_id)` — returns `%{status, container_name, overlay_method}` or `nil`

**Container start strategy (in `init/1`):**
1. Try **overlay container**: `podman run --cap-add=SYS_ADMIN` with three volume mounts, runs `mount -t overlay` inside the container. Verifies container stays running.
2. If that fails, try **fallback container**: bind-mount lower as `/workspace_lower:ro` and upper as `/workspace:rw`. Reads/writes go through `Orchid.Sandbox.Overlay` on the Elixir side.
3. If both fail, status = `:error`, agent works without isolation.

**Important:** All paths are expanded to absolute via `Path.expand()` because podman requires absolute paths for `-v` mounts.

**Image:** Reads from fact `"sandbox_image"`, defaults to `orchid-sandbox:latest`.
The default sandbox image includes the runtime tools agents need for benchmark
closure checks, including Node.js, Erlang/Elixir, and Mix.

### `lib/orchid/tools/sandbox_reset.ex`
Tool (`@behaviour Orchid.Tool`) that lets the agent reset its own sandbox.
- Name: `"sandbox_reset"`
- Calls `Orchid.Sandbox.reset(state.id)` from agent context

### `test/orchid/project_test.exs`
Tests for Project directory management — ensure_dir, delete_dir, canary file write+read.

### `test/orchid/sandbox_overlay_test.exs`
Tests for the union FS fallback — union_read (upper wins), union_write, union_list (merge + dedup).

### `test/orchid/sandbox_test.exs`
Integration tests with real podman containers:
- Lifecycle (start, stop, status)
- exec (echo, pwd)
- File ops (write goes to upper not lower, canary read from lower)
- Agent isolation (agent B can't see agent A's files)
- Both agents can read shared project files
- Reset preserves upper data
- edit_file, list_files

### `test/orchid/agent_sandbox_test.exs`
Agent + sandbox integration:
- Agent with project_id gets a sandbox, without doesn't
- Tool dispatch routes shell/read/edit/list/grep through sandbox
- Canary file placed in project dir is readable via tool dispatch
- Non-sandboxed tools (eval) still run directly
- reset_sandbox via Agent API
- Stopping agent destroys container

---

## Modified Files

### `lib/orchid/tool.ex`
- Added `Orchid.Tools.Shell` and `Orchid.Tools.SandboxReset` to `@tools` list (was 8, now 11)
- Added `@sandboxed_tools ~w(shell read edit list grep)`
- `execute/3` checks: if tool is sandboxed AND agent has active sandbox, routes through `execute_in_sandbox/3` which calls `Orchid.Sandbox.*` functions
- `sandbox_active?/1` checks `context.agent_state.sandbox` is not nil/false

### `lib/orchid/agent.ex`
- **State struct**: added `:sandbox` field (nil or status map)
- **`init/1`**: returns `{:ok, state, {:continue, :start_sandbox}}` when `project_id` is set (avoids DynamicSupervisor deadlock — both agent and sandbox are children of the same supervisor)
- **`handle_continue(:start_sandbox)`**: starts `Orchid.Sandbox` as child of `Orchid.AgentSupervisor`, stores status in state
- **`reset_sandbox/1`** client API + `handle_call(:reset_sandbox)`: calls `Sandbox.reset`, updates state
- **`terminate/2`**: calls `Sandbox.stop(state.id)` if sandbox exists

### `lib/orchid_web/live/agent_live.ex`
- **Mount/handle_params**: added `:sandbox_active` and `:sandbox_status` assigns
- **`create_project` handler**: calls `Orchid.Project.ensure_dir(project.id)` after creating object
- **`delete_project` handler**: calls `Orchid.Project.delete_dir(id)` before deleting object
- **`reset_sandbox` event handler**: calls `Agent.reset_sandbox`, updates assigns
- **Render — project detail**: shows `Folder: <path>` under project name
- **Render — agent cards**: shows sandbox status badge if present
- **Render — chat view**: shows sandbox status bar with Reset button when sandbox is active
- **`list_agents_with_info/0`**: returns `sandbox_status` in agent map

### `lib/orchid_web/live/prompts_live.ex`
- `create_project`: added `Orchid.Project.ensure_dir`
- `delete_project`: added `Orchid.Project.delete_dir`

### `lib/orchid_web/live/settings_live.ex`
- Same project dir hooks as prompts_live

### `config/test.exs`
- Sets `data_dir` to `"tmp/test_data"` so tests don't pollute production data
- Disables endpoint server and uses port 4002

### `test/orchid_test.exs`
- Updated tool count assertion from 8 to 11
- Updated tool name assertions to match new tools

---

## Key Design Decisions

1. **`handle_continue` for sandbox start** — Agent init can't call `DynamicSupervisor.start_child` on the same supervisor it's being started from (deadlock). Using `handle_continue` defers sandbox creation until after init returns.

2. **Two-tier container fallback** — Real overlay mount inside rootless podman requires `--cap-add=SYS_ADMIN`. If that fails (permissions, kernel), falls back to bind-mounting upper as `/workspace` with Elixir-side union merging.

3. **Absolute paths for podman** — `Path.expand()` on data_dir and lower_path because podman interprets relative paths as named volumes, not bind mounts.

4. **Sandbox registered as tuple key** — `{:sandbox, agent_id}` in the same `Orchid.Registry` avoids conflicts with agent string keys.

5. **Graceful degradation** — If sandbox fails to start, agent still works with `sandbox: nil`, tools run directly on host.

---

## Status / Known Issues

- **Podman overlay mount inside rootless container** may need additional kernel config (`/proc/sys/kernel/unprivileged_userns_clone`). Falls back to union mode automatically.
- **Pre-existing test flake**: `"stop agent removes it from list"` in `orchid_test.exs` has a race condition on Registry cleanup (50ms sleep sometimes insufficient). Not introduced by this change.
- The `Shell` tool module already existed at `lib/orchid/tools/shell.ex` but was not in the `@tools` list. Now it is.

---

## How to Continue

```bash
# Compile (must be clean)
mix compile --warnings-as-errors

# Run all tests
mix test

# Run only sandbox integration tests
mix test test/orchid/sandbox_test.exs test/orchid/agent_sandbox_test.exs

# Check containers
podman ps --filter "name=orchid"

# Clean up stale test containers
podman rm -f $(podman ps -aq --filter "name=orchid")
```
