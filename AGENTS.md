# lxit internals

Tech details for working on lxit itself. Usage (CLI, `lxit` API, bins) lives in `SKILL.md`.

## Layout

No shared types module: each type lives with its owner (`lib/init` re-exports `env`/`args`/`cmd`/`task_fn`). One job per file; each talks to few lxit modules (arrow = requires). No setup/init fns: flags parse argv at require; env loads lazily on first read (modules cannot yield at require time). Public API: `lib/init` injected as the `lxit` global into `tasks.luau` (`cli/run` loads it via `luau.load` with its own env — lute `_G` is readonly, so modules it requires don't get it); typed by `lxit.d.luau` (keep in sync with `lib/init`).

- `cli/run.luau` — entry (compiled to the `lxit` binary): dispatch task, `run`/`watch` commands, print help (ro-sync/clap style: bold yellow headers, green padded first column, dim descriptions; env vars colored by `utils/env` presence). → `lib`, `cli/analyze`, `utils/env`
- `cli/analyze.luau` — static analysis of `tasks.luau` via `@std/syntax`; returns data only (`{ params: { name, choices?, optional }, env: { name, kind, optional }, doc }` per task, no colors); `doc` = comment trivia directly above the `local` keyword. AST nodes typed `any`: lute's typedefs use `read` props the old solver can't index. → none
- `lib/init.luau` — public `lxit` API facade (`flags` for the cli). → `binary`, `flags`, `print_task`, `task_graph`, `watch`, `utils/env`
- `lib/flags.luau` — argv flags (`-f`/`--force`, `--dry-run`, `-y`/`--yes`) + remaining `args` (command, task, task args), frozen. → none
- `lib/task_graph.luau` — task nodes (owns `node`/`task_fn` types), freshness, steps, `depends`/`outputs`, parallel branches; no formatting. → `flags`, `print_task`, `utils/glob`
- `lib/print_task.luau` — all call-tree printing (takes a structural `owner` = `{ call, depth, parent }`, so it needs no task_graph types): call descriptions, lazy headers (printed at a node's first step: dim `·` fresh + steps hidden, else yellow `~`; ancestors first), step marks (`fresh`/`dry`/`run`), per-branch buffers (a `run` step flushes); lines go through `env.redact`. → `utils/env`
- `lib/watch.luau` — task rerun loop on change; flushes its branch buffer after each rerun. → `flags`, `print_task`, `task_graph`, `utils/watch`
- `lib/binary/init.luau` — bin objects, argv, exec; owns `args`/`cmd<A>` types. → `resolve`, `spec`, `task_graph`, `utils/env`
- `lib/binary/spec.luau` — `owner/repo[@version]` parsing. → none
- `lib/binary/storage.luau` — rokit tool-storage lookup (list installed versions) + store. → `spec`, `utils/version`
- `lib/binary/install.luau` — send github requests, pick OS/arch zip, extract exe in memory, store. → `spec`, `storage`, `utils/github`, `utils/unzip`
- `lib/binary/resolve.luau` — pick tool version + prompt; picks last for the process only. → `flags`, `install`, `spec`, `storage`, `utils/version`

General purpose, no lxit deps (`utils/`):

- `utils/env.luau` — `.env` + process env, lazy, typed reads (`string`/`number`/`bool`), `await_is_set(name)`; `secret.string` registers its value, `redact(text)` swaps registered values for `***` (lxit's own prints only: child stdio is inherited, lute has no streaming pipe).
- `utils/version.luau` — semver compare.
- `utils/glob.luau` — `match(pattern, path)`, `await_expand(pattern) -> (files, dirs walked)`; `*` `?` `**` `{a,b}` (spec: `tests/lute/glob.spec.luau`).
- `utils/watch.luau` — `new(on_change)` + `await_add(watcher, path, glob?)`: per-dir `fs.watch` handles (non-recursive), optional glob filter on event names; unwatched new dirs always notify; deleted dirs (and their subdirs) get their handles closed and dropped.
- `utils/github.luau` — pure GitHub REST request builders (ernisto/ro-cloud style endpoints: `latest_release`, `release_by_tag`, `download_asset`; `endpoint:request(token, path)`); callers send.
- `utils/unzip/` — vendored 0x5eal/unzip 0.2.1 (MIT, `LICENSE.md`); not stylua-formatted (`.styluaignore`), don't edit.

## Freshness

- Node key `{name}:{outputs or depends}`; `running[key]` serializes same-key nodes across parallel branches (second waits, then sees fresh).
- Decided lazily at a node's first step: scan depends (recursive mtime, globs = newest match), then outputs (oldest of each output's newest mtime).
- In-process memory `runs[key] = { newest, signature }`: newest depends mtime seen at decision + first step's argv. Avoids wall-clock compares (`os.time` is whole seconds, `@std/time` is monotonic).
- A child with outputs that reran marks all ancestors dirty.
- Dry run: missing depends count as stale (a sibling's output never got made), no memory recorded.
- Deleting a glob match lowers nothing, so deletions alone don't make a node stale (`ponytail:` in `task_graph`).

## Tool resolution

Lazy, inside the step's perform (tree already flushed, so prompts land in order). Pinned version installed → use it; no version → newest installed. Missing → prompt: `[i]` install / `[a]` abort, then `[1..n]` every installed version newest first; after the answer the prompt lines are erased (`ESC[nF ESC[J`, sent via `print` so it stays ordered with buffered output) and replaced by one outcome line (`using installed …` / `installing …` then `installed …` / `aborted …`); `--yes` → install. Install: `release_by_tag` (`v{ver}` then `{ver}`) or `latest_release`, pick `.zip` asset by OS then arch patterns, `download_asset` (octet-stream, follows redirect), unzip in memory, prefer `{repo}.exe` over any `.exe`, write to storage (`chmod +x` off Windows). `GITHUB_TOKEN` from env if set.

## Typing

- `lxit.run` / `lxit.bind` / `lxit.call` are fixed-arity generics (max 3 args): variadic generics widen string literals and break arg autocomplete.
- Bins are metatables; the typed surface is a cast at the `lxit.bin` call site (`lxit_cmd<A>` global type).

## Lute gotchas

- Modules cannot yield at require time (fs calls yield) — lazy-load state; scripts used from tasks must export a function.
- `@lute/vm` calls that yield never return; parallelism is `task.spawn` + concurrent `process.run`.
- `fs.watch` is non-recursive (`utils/watch` registers every dir).
- `io.input` hangs under non-console stdin pipes → `--yes`.
- Child process stdout can print before buffered tree lines when redirected.

## Release

Publishing a GitHub release runs `.github/workflows/release.yml`: `lute compile cli/run.luau` on one runner per platform (no cross target) → `lxit-<tag>-<os>-<arch>.zip` (ro-sync / rokit naming), plus `lxit.d.luau`, uploaded to the release. Version = git tag; nothing to bump. No README.md. Run locally: `lute run cli/run.luau ...` from a dir with `tasks.luau`.
