# Agents

Project-specific subagent definitions for `traject-solr_pool`.

When a task in this project benefits from a dedicated subagent (a focused
reviewer, a migration helper, a release auditor, etc.), define it here as one
Markdown file per agent. Keep each agent's responsibility narrow and its
instructions self-contained, so it can run without the parent session's
context.

## File convention

- One file per agent: `docs/agents/<agent-name>.md`.
- Start with a short purpose line: what the agent does and when to reach for it.
- List the tools it needs and the inputs it expects (file paths, not pasted
  context).
- Describe the report format it must return.

## Reusable from the sibling `http_connection_pool` gem

This gem shares that gem's thread-safety and security constraints, so several of
its agents transfer directly (see `../../../http_connection_pool/docs/agents/`).
Adapt the file paths/tags to this project when reused:

- `concurrency-spec-reviewer` — reviews concurrency specs for assertions a race
  can invalidate, then stress-loops them for flakiness. Directly applicable to
  our `:thread_safety` and `:background_jobs` integration specs.
- `dependency-security-auditor` — audits the dependency tree against primary
  sources (RubyGems API, GitHub advisory DB). Applicable to our gemspec/Gemfile,
  especially while we carry the temporary edge-traject `path:` override.
- `memory-leak-auditor` — hunts unbounded retention with `ObjectSpace`/`GC`
  probes. Applicable to verifying the writer/pool do not accumulate objects
  per-batch or per-job.

## Defined agents

_None yet. Candidate for this project:_

- **writer-parity-reviewer** — diff our `Traject::SolrPool::SolrJsonWriter`
  against the stock `Traject::SolrJsonWriter` to confirm settings/method-surface
  parity and flag any silently-dropped behaviour. Advisory only.
