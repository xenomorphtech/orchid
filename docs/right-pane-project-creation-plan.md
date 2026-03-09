# Right-Pane Project Creation Plan

## Problem

Today, project creation is a sidebar-only, name-only action:

- `lib/orchid_web/live/agent_live.ex:29-30` stores only `creating_project` and `new_project_name`.
- `lib/orchid_web/live/agent_live.ex:437-465` handles create/cancel/update with only a trimmed name.
- `lib/orchid_web/live/agent_live.ex:1015-1057` renders the inline sidebar form.
- The same pattern is duplicated in `lib/orchid_web/live/prompts_live.ex:105-133` and `lib/orchid_web/live/settings_live.ex:152-180`.
- `lib/orchid/projects.ex:9-13` and `lib/orchid/tools/project_create.ex:12-40` only accept `name`.

A project can therefore be created without an objective, constraints, deliverables, or any kickoff context. That is too little information for a meaningful project workspace.

## Goals

- Move new-project creation into the right-hand workspace, not the left navigation column.
- Require enough information for the project to be actionable immediately after creation.
- Keep the left sidebar focused on browsing, searching, and selecting projects.
- Preserve one canonical project-creation contract across LiveView and tool entry points.
- Give the captured project brief a persistent home after creation.

## Non-Goals

- Do not auto-spawn an agent just because a project was created.
- Do not redesign the entire dashboard layout beyond what is needed for the new flow.
- Do not keep multiple ad hoc project-creation forms with slightly different fields.

## Proposed UX

### Entry

1. The user clicks `+ New` in the left project sidebar.
2. The sidebar stays a navigation surface; it does not expand into an inline form.
3. The main pane switches into a `New Project` workspace state on the right.

If an agent chat is currently open, `+ New` should move the user back to the dashboard workspace first, then activate the new-project view. Project creation is a workspace action, not a chat-side overlay.

### Right-Pane Structure

Introduce a separation between:

- workspace mode: `:project` or `:new_project`
- project tab: `:overview`, `:goals`, `:decomposition`

Do not overload the existing `project_tab` assign to mean both "existing project subtab" and "creation mode". Keeping those states separate will make the render logic and events much easier to reason about.

### Form Sections

Required:

- Project name
- Objective
- Definition of done / success criteria

Optional but strongly encouraged:

- Background / context
- Constraints / non-goals
- Relevant paths, repos, or assets
- Suggested first goal
- Default template for future agents
- Default execution mode

The form should read like a project brief, not a label maker.

### Submit Flow

1. Validate required fields inline.
2. Create the project record and project directory.
3. Optionally create a first pending goal if `suggested first goal` is present.
4. Select the new project.
5. Land on that project's `Overview` tab, showing the saved brief and next actions:
   - Add goal
   - Open decomposition lab
   - Create agent

### Cancel Flow

- `Cancel` exits the `New Project` workspace state.
- If a project was previously selected, return to that project's last tab.
- If nothing was selected, return to the default dashboard empty state.

## Data Contract

### Canonical Create API

Change the backend from `create(name)` to `create(attrs)` with a compatibility wrapper if needed during rollout.

Suggested shape:

```elixir
%{
  name: "...",
  objective: "...",
  success_criteria: "...",
  background: "...",
  constraints: "...",
  relevant_paths: ["..."],
  kickoff_goal: "...",
  default_template_id: "...",
  default_execution_mode: :vm | :host
}
```

Recommended behavior:

- Store structured fields in project `metadata`.
- Store a human-readable markdown brief in project `content`.
- Continue to default `metadata.status` to `:active`.

This is a good use of the currently underused project `content` field: the overview tab can render it directly, and agents/tools can read it as the project's durable brief.

### Backward Compatibility

Existing projects with empty `content` and sparse metadata should remain valid.

Fallback behavior:

- `Overview` tab renders whatever metadata/content is available.
- Missing fields display as empty or "not set".
- No migration is required before shipping the UI.

## AgentLive Changes

### State

Replace the minimal creation state in `lib/orchid_web/live/agent_live.ex:29-30` with a richer form assign, for example:

```elixir
project_workspace_mode: :project | :new_project
new_project_form: %{
  name: "",
  objective: "",
  success_criteria: "",
  background: "",
  constraints: "",
  relevant_paths_text: "",
  kickoff_goal: "",
  default_template_id: nil,
  default_execution_mode: :vm
}
```

`relevant_paths_text` can be a textarea in the UI and normalized into a list before persistence.

### Events

Add or reshape events around the new state:

- `show_new_project`
- `cancel_new_project`
- `update_new_project_form`
- `create_project`
- `set_project_tab`
- optionally `set_project_workspace_mode`

The existing `update_new_project_name` event should disappear once the form becomes structured.

### Rendering

In `lib/orchid_web/live/agent_live.ex`:

- Remove the inline sidebar form at `:1042-1057`.
- Keep the sidebar list and `+ New` button.
- Add an `Overview` tab for existing projects alongside `Goals` and `Decomposition Lab`.
- Add a right-pane `New Project` screen that reuses the same visual language as project detail cards.

The overview tab matters because the new richer project data needs a place to live after submit. Without it, the form collects context that immediately becomes invisible.

## Other Screens

`PromptsLive` and `SettingsLive` currently create projects directly with `Object.create(:project, name, "")`.

That should not remain the long-term model.

Recommended approach:

- Short term: route all project creation through `Orchid.Projects.create(attrs)`.
- Preferred UI behavior: if those screens still need project creation, send users into the same canonical right-pane workflow instead of maintaining separate reduced forms.

The main goal is to stop multiplying divergent create paths.

## Tooling Changes

`lib/orchid/tools/project_create.ex` should evolve with the same contract.

Minimum change:

- require `name`
- require `objective`
- require `success_criteria`

Optional fields can mirror the UI contract.

That keeps tool-created projects from being permanently lower-fidelity than UI-created projects.

`project_list` can remain mostly unchanged, though later it may be useful to include a short objective summary.

## Implementation Order

1. Extend `Orchid.Projects` with a structured `create(attrs)` contract and validation.
2. Teach `project_create` to use the same contract.
3. Refactor `AgentLive` state away from `creating_project` + `new_project_name`.
4. Replace the sidebar form with a right-pane `New Project` view.
5. Add the persistent `Overview` tab for saved project briefs.
6. Update `PromptsLive` and `SettingsLive` to stop bypassing the shared project API.
7. Add coverage for the new create flow before any follow-on polish.

## Tests

### Backend

- `Orchid.Projects.create(attrs)` stores metadata, markdown content, and project directory.
- validation rejects blank `name`, `objective`, or `success_criteria`.
- optional kickoff goal creation behaves predictably.

### Tools

- `project_create` rejects incomplete payloads.
- `project_create` returns the new project id and files path on success.

### LiveView

- `+ New` opens the right-pane new-project state instead of rendering a sidebar form.
- submit failures keep the user on the form with validation messages.
- successful submit selects the new project and lands on `Overview`.
- cancel returns to the prior workspace state.
- clicking `+ New` while a chat is open returns to workspace mode cleanly.

## Defaults To Ship

- Required fields: `name`, `objective`, `success_criteria`
- Do not auto-start an agent
- Create a kickoff goal only when explicitly provided
- Land on `Overview` after create
- Keep old projects readable without migration

## Recommendation

Treat this as a project-brief feature, not a relocated input box. The right-pane tab should create a project that already contains enough context for goals, decomposition, and agent work to make sense on first open.
