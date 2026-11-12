---
name: lxit
description: Write and run lxit tasks (lute task runner binary, ernisto/lxit) — task fns in tasks.luau, lxit.run/lxit.call/lxit.all/lxit.bind/lxit.depends/lxit.outputs/lxit.fetch/lxit.watch, typed bins via lxit.bin, caching, dry-run, tool resolution. Use when editing tasks.luau or bin types.
---

# lxit

Task runner on lute, shipped as a compiled binary (`lxit = "ernisto/lxit@<version>"` in rokit/aftman). Tasks are plain named functions returned in a table from `tasks.luau` in the working directory.

## CLI

`lxit [-f|--force] [--dry-run] [-y|--yes] <command> <task> [args]` — commands: `run` (once), `watch` (rerun on change to any depends path seen).

- No command → help, in order: commands, options, env vars (every var any task reads, with status), tasks + args parsed from `tasks.luau` (call style: `lint(dev | lobby | match?)` — literal-union params (direct or via a type alias) show their choices, others their name, `?` = optional).
- `--force` reruns everything. `--dry-run` runs no command/fetch/call, treats missing depends as stale, `watch` runs once. `--yes` auto-installs missing tools (needed for CI / non-console stdin).
- Env from `.env` merged over process env, frozen; read via `lxit.env.*` (below). Commands inherit it.
- Task description = the `--` comment block right above its `local function` (no blank line between), then `(needs env: …)`.
- Task list also shows env vars each task reads (`NAME?` = has default), found statically through the task's body and every local fn it references: dim = set, yellow = unset but has a default, red = unset and required.

## API

`tasks.luau` runs with the `lxit` global (modules it requires don't see it); alias fns as locals: `run`, `call`, `all`, `bind`, `depends`, `outputs`, `fetch`, `watch`, `env`. Types: `lxit.d.luau` release asset, e.g. luau-lsp `definitionFiles: { "lxit": "https://github.com/ernisto/lxit/releases/latest/download/lxit.d.luau" }`.

- `lxit.run(task_fn, ...)` opens a task node (fn must be named — the name keys freshness), returns the fn's results.
- `lxit.run(bin.sub.cmd, args, env?)` runs a command step. `args` table: positional entries + `key = value` → `--key value` (`_`→`-`, 1-char → `-k`, `true` → bare flag, `false`/nil skipped, array → repeated flag); flags go before positionals.
- `lxit.call(fn, ...)` runs a Luau fn as a cached step (results dropped — a fresh step skips fn).
- `lxit.fetch(url, path)` download step.
- `lxit.env.string(name, default?)` / `lxit.env.number(...)` / `lxit.env.bool(...)` (`true|false|1|0|yes|no`) read env inside tasks; no default → required, missing/empty errors loud. Use the paren form `env.string('X', d)` for defaults so the task list sees it. `lxit.env.secret.string(name, default?)` reads like `string` but masks the value as `***` in everything lxit prints (call tree, errors) — not child process stdio, so still pass secrets to commands as child env (3rd `lxit.run` arg), never as flags.
- `lxit.depends(...)` / `lxit.outputs(...)` declare the current node's inputs/outputs (`outputs` creates parent dirs). `depends` takes globs too (`'places/**/*.luau'`, `'{client,server}/*.luau'`; `*`/`?` within a segment, `**` across): mtime is the newest match, watch mode only reacts to matching files (plus new dirs under the glob). Must be inside a task node.
- `lxit.all(fn, lxit.bind(fn, ...), ...)` runs entries in parallel, returns each entry's first result in order; first failure rethrown after all finish. Same task + paths in two branches runs once.
- `lxit.watch(fn, ...)` reruns fn forever on change.
- `lxit.run` / `lxit.bind` / `lxit.call` take at most 3 args after the target.

## Caching

Nothing is persisted. A task's steps skip (make-style) when not `--force`, all outputs exist, every output is at least as new as every depends path, and no child task with outputs reran. Within one process (watch, shared tasks) a rerun also needs unchanged command args. Tasks without outputs always run on a fresh invocation. A command that leaves its outputs untouched (e.g. `pesde install` with an unchanged lock) reruns until an output gets newer.

## Output

Call tree: per task, dim `· name(args)` when fresh (steps hidden), else yellow `~ name(args)` then white steps — `>` ran, `~` would run (dry-run). A task header prints at its first step (when freshness is known); an ancestor printed before deciding shows blue, its fresh steps as dim `·`. Parallel branches buffer per branch; `…` re-prints the header a line belongs to when branches interleave.

## Bins

Made in `tasks.luau`: `lxit.bin 'owner/repo[@version]' :: <type>`, with per-subcommand arg types (`lxit_cmd<{ flag: type? }>`, global type) — keep the types in a required module if long — add flags there for autocomplete. Indexing appends subcommands (`rojo.plugin.install`); dynamic subcommands typed as `{ [string]: cmd<...> }` indexers.

Resolved from rokit storage `~/.rokit/tool-storage/<owner>/<repo>/<version>` (no version = newest installed). Resolution is lazy (only when a step really runs), cached per run. Missing → prompt: install from GitHub / abort, then any installed version (listed newest first). The pick lasts for this run only.

## Gotchas

- Scripts used from tasks must export a function, not do work at top level (lute modules cannot yield at require time).
- Non-console stdin (CI, pipes) → pass `--yes`.

Internals (module map, freshness mechanics, tool install, typing notes): `AGENTS.md` in ernisto/lxit.
