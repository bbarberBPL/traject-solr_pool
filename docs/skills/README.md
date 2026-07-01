# Skills

Project-specific skills for `traject-solr_pool`.

When a repeatable workflow emerges in this project (a release checklist, a
dependency-audit routine, a Solr round-trip verification), capture it here as a
skill so future sessions follow the same steps instead of rediscovering them.

## File convention

- One directory per skill: `docs/skills/<skill-name>/SKILL.md`.
- The `SKILL.md` opens with YAML frontmatter (`name`, `description`) describing
  when the skill applies, followed by the steps.
- Keep steps concrete and ordered; prefer checklists the session can turn into
  todos.
- Reference supporting files by relative path within the skill directory.

## Reusable from the sibling `http_connection_pool` gem

See `../../../http_connection_pool/docs/skills/`. These transfer with minor path
changes:

- `dependency-audit` — security sweep that verifies every advisory/version claim
  against primary sources before recommending a change. Reuse verbatim; it is
  especially relevant while the edge-traject `path:` override is in place.
- `memory-leak-audit` — drives churn and measures retention with
  `ObjectSpace`/`GC` rather than reading code. Adapt the churn driver to enqueue
  writer batches / background jobs against a WebMock-stubbed Solr.

## Defined skills

_None yet. Candidates for this project:_

- **edge-traject-cutover** — the checklist to remove the temporary
  `path: '../traject-edge'` Gemfile override and pin the real released traject
  once a release lifts the `http < 6` cap (verify the published version via the
  RubyGems API, update the gemspec constraint, drop the override, re-run
  `rake ci`).
- **solr-roundtrip-verify** — bring up a local Solr, run a real index + commit +
  delete round-trip through the pooled writer, and confirm connection reuse via
  registry stats (mirrors the sibling gem's `examples/solr_update_demo.rb`).
