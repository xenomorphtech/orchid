# Knowledge Graph Plan

## Problem

Orchid already has:

- project briefs and defaults stored on project objects
- global facts for secrets and small configuration values
- project workspaces on disk

What it does not have is a shared, queryable model for operational context such as:

- which git repo a project should clone
- which branch or commit to pin
- which remote files or URLs matter
- which local workspace paths are authoritative
- which global sources are reusable across projects

That leaves orchestrators, tools, and the UI to infer source context from free-form text or ad hoc metadata.

## Goal

Add a knowledge graph that both orchestrators and the UI can read and write, with two explicit scopes:

- `global`: reusable knowledge shared across projects
- `project`: project-specific knowledge and overrides

The first version should focus on source orchestration, not generic world knowledge.

## Non-Goals

- Do not move secrets out of facts. Graph nodes should reference facts, not embed secret values.
- Do not model every object in Orchid as a graph node on day one.
- Do not build a semantic/vector graph first. Start with explicit typed entities and edges.
- Do not replace the existing project brief flow. The graph should complement it.

## Design Principles

- Reuse current concepts where they already fit: `project` objects remain the durable project brief.
- Keep scope explicit. Global and project records should not be mixed implicitly.
- Preserve provenance. Every graph assertion should say where it came from.
- Prefer typed nodes and edges over free-form blobs.
- Make the read path cheap for orchestrators.
- Keep the first slice narrow: repos, remote files, web resources, workspace paths, and their relationships.

## Scope Model

Use a scope tuple on every node and edge:

```elixir
{:global}
{:project, project_id}
```

Resolution rules:

1. Read project-scoped knowledge first.
2. Then include global nodes explicitly linked into that project.
3. Allow project scope to override global defaults by canonical key.

This keeps global knowledge reusable without making every project inherit everything.

## Graph Model

### Node

Suggested shape:

```elixir
%Orchid.Knowledge.Node{
  id: "...",
  scope: {:global} | {:project, project_id},
  kind: :project_root | :git_repo | :repo_checkout | :remote_file | :web_resource | :workspace_path | :document_bundle,
  key: "canonical-key-within-scope",
  name: "Human label",
  attrs: %{},
  status: :active | :stale | :error | :archived,
  provenance: %{
    source_type: :ui | :tool | :seed | :import | :discovery,
    source_ref: "...",
    observed_at: ~U[2026-03-09 00:00:00Z]
  },
  inserted_at: ...,
  updated_at: ...
}
```

### Edge

Suggested shape:

```elixir
%Orchid.Knowledge.Edge{
  id: "...",
  scope: {:global} | {:project, project_id},
  subject_id: "...",
  predicate: :uses | :contains | :derived_from | :cached_as | :auth_via | :tracks | :overrides,
  object_id: "...",
  attrs: %{},
  provenance: %{...},
  inserted_at: ...,
  updated_at: ...
}
```

### Why Not Reuse `:fact`

`fact` is currently name/value oriented and works well for secrets and small configuration values. A graph needs:

- multiple node kinds
- relationships
- scope-aware lookup
- provenance
- efficient traversal

That is a separate concern. Facts should stay as referenced credentials and settings.

## Recommended First-Class Node Types

### Global

- `:git_repo`
  - repo URL
  - host
  - default branch
  - auth fact reference if needed
- `:remote_file`
  - URL
  - mime type
  - checksum or etag
  - auth fact reference if needed
- `:web_resource`
  - URL
  - title
  - description
- `:document_bundle`
  - label for a curated set of links or files

### Project

- `:project_root`
  - absolute workspace path
- `:repo_checkout`
  - checkout path
  - branch
  - pinned commit
  - sync policy
- `:workspace_path`
  - relevant file or directory inside the project workspace
- `:remote_file`
  - project-specific remote input
- `:web_resource`
  - project-specific doc or reference

## Recommended Edge Types

- `project_root --contains--> workspace_path`
- `repo_checkout --derived_from--> git_repo`
- `project_root --uses--> repo_checkout`
- `project_root --uses--> remote_file`
- `project_root --uses--> web_resource`
- `remote_file --cached_as--> workspace_path`
- `git_repo --auth_via--> fact`
- `remote_file --auth_via--> fact`
- `project node --overrides--> global node`

The main value is not deep graph theory. It is making source decisions explicit and inspectable.

## Provenance And Freshness

Each node and edge should carry provenance metadata. Minimum useful fields:

```elixir
%{
  source_type: :ui | :tool | :seed | :import | :discovery,
  source_ref: "event id, file path, tool run id, or URL",
  observed_at: DateTime.t(),
  observed_by: agent_id | "user" | nil
}
```

For network-backed sources add freshness fields in `attrs`:

- `last_checked_at`
- `etag`
- `checksum`
- `http_status`
- `commit_sha`
- `fetch_status`

That lets the UI show whether a repo/file reference is current, stale, or broken.

## Storage Recommendation

Do not force this into the current generic `Object` table as raw blobs.

Recommended path:

- add `Orchid.Knowledge` as a dedicated context
- back it with CubDB initially, since the project already uses CubDB
- maintain explicit secondary indexes for:
  - nodes by scope
  - nodes by scope and kind
  - nodes by scope and key
  - edges by scope and subject
  - edges by scope and object

This stays consistent with current storage choices while avoiding full-table scans for every graph query.

If traversal and filtering grow more complex later, this can move to SQLite without changing the public API.

## API Surface

### Context API

Suggested first-pass API:

```elixir
Orchid.Knowledge.upsert_node(scope, kind, attrs)
Orchid.Knowledge.upsert_edge(scope, subject_id, predicate, object_id, attrs \\ %{})
Orchid.Knowledge.get_node(id)
Orchid.Knowledge.find_node(scope, kind, key)
Orchid.Knowledge.list_nodes(scope, opts \\ [])
Orchid.Knowledge.list_edges(scope, opts \\ [])
Orchid.Knowledge.resolve_project_graph(project_id)
Orchid.Knowledge.delete_node(id)
Orchid.Knowledge.delete_edge(id)
```

### Source-Oriented Helpers

These are what orchestrators will actually want:

```elixir
Orchid.Knowledge.Sources.list_for_project(project_id)
Orchid.Knowledge.Sources.project_checkout(project_id)
Orchid.Knowledge.Sources.remote_inputs(project_id)
Orchid.Knowledge.Sources.ensure_checkout(project_id)
Orchid.Knowledge.Sources.fetch_remote_file(node_id)
```

The graph should be the source of truth. Helpers just package common traversals.

## UI Surface

Add a `Sources` area in the project workspace with:

- global sources linked into the project
- project-only sources
- sync status and provenance
- actions:
  - add repo
  - link global repo
  - pin branch or commit
  - add remote file
  - add URL
  - refresh metadata
  - detach or archive source

Recommended layout:

- `Overview`: project brief and high-level summary
- `Sources`: graph-backed operational context
- `Goals`
- `Decomposition`

Global settings can expose a `Knowledge` or `Sources` page for reusable shared nodes.

## Orchestrator Interaction

The orchestrator should stop inferring source setup from free-form text whenever possible.

Expected flow:

1. User creates a project brief.
2. User or tool adds sources to the project graph.
3. Orchestrator resolves the project graph.
4. If a `repo_checkout` is missing but a linked `git_repo` exists, the orchestrator can propose or perform checkout.
5. If remote files are declared, the orchestrator can fetch/cache them into workspace paths.
6. Agents receive a compact source context derived from the graph, not the whole graph dump.

Derived agent context should include:

- workspace root
- active checkout path
- repo URL and pinned revision if present
- declared remote inputs
- relevant workspace paths
- source freshness warnings

## Relationship To Existing Project Data

Keep current project metadata for:

- objective
- success criteria
- background
- constraints
- default template
- default execution mode

Do not duplicate those fields into the graph initially.

`relevant_paths` is the only field that overlaps. Recommended handling:

- keep it for backward compatibility
- when a project is edited through the new sources UI, convert those paths into `workspace_path` nodes
- eventually treat the graph as canonical for path-level source context

## Suggested Data Examples

### Global Repo

```elixir
%{
  scope: {:global},
  kind: :git_repo,
  key: "github:acme/platform",
  name: "Acme Platform Repo",
  attrs: %{
    url: "git@github.com:acme/platform.git",
    host: "github.com",
    default_branch: "main",
    auth_fact_name: "github_deploy_key"
  }
}
```

### Project Checkout

```elixir
%{
  scope: {:project, project_id},
  kind: :repo_checkout,
  key: "primary-checkout",
  name: "Primary checkout",
  attrs: %{
    checkout_path: "/abs/path/to/project/files/platform",
    branch: "release/2026-03",
    commit_sha: "abc123",
    sync_policy: :manual
  }
}
```

### Project Remote File

```elixir
%{
  scope: {:project, project_id},
  kind: :remote_file,
  key: "requirements-doc",
  name: "Requirements Document",
  attrs: %{
    url: "https://example.com/spec.pdf",
    mime: "application/pdf",
    cached_path: "/abs/path/to/project/files/input/spec.pdf",
    fetch_status: :fetched
  }
}
```

## Rollout Plan

### Phase 1: Source Graph Backbone

- add `Orchid.Knowledge.Node` and `Orchid.Knowledge.Edge`
- add CubDB-backed storage and indexes
- add CRUD/query API
- add project graph resolution
- add unit tests for scope and override behavior

### Phase 2: Project Sources UI

- add `Sources` tab in `AgentLive`
- show project and linked global sources
- allow add/edit/link/archive actions
- show provenance and sync status

### Phase 3: Orchestrator Integration

- add source resolution in planner/orchestrator setup
- add repo checkout and remote fetch helpers
- pass a normalized source summary into agent prompts and tools

### Phase 4: Migration and Cleanup

- optionally migrate `relevant_paths` into `workspace_path` nodes
- keep facts for secrets
- consider extending the graph to goals, artifacts, or agents only if a concrete use case appears

## Minimum Viable Slice

If you want the smallest useful implementation, ship only:

- global `git_repo`
- project `repo_checkout`
- project `remote_file`
- project `workspace_path`
- `uses`, `derived_from`, `cached_as`, and `auth_via` edges
- a `resolve_project_graph/1` API
- a simple project `Sources` editor in the UI

That is enough to answer:

- should this project clone a repo
- where should it live
- what revision should it use
- what remote files should be fetched
- what local files matter

## Recommendation

Treat this as a scoped source graph attached to projects, not a general AI memory system.

That keeps the model operational:

- small enough to implement quickly
- explicit enough for orchestration
- inspectable enough for users
- compatible with the current project brief and facts model
