-- lxit task runner global, injected into tasks.luau

type lxit_env = { [string]: string }
type lxit_cmd<A> = (args: A?, env: lxit_env?) -> ()
type lxit_task_fn = (...any) -> ...any

declare lxit: {
	-- typed handle to a rokit tool `owner/repo[@version]`; index appends subcommands, call runs it
	bin: (id: string) -> any,

	-- task fn: open a task node and return its results; bin: run a command step `(args, env?)`
	run: <A, B, C, R...>(target: (A, B, C) -> R..., a: A?, b: B?, c: C?) -> R...,
	-- run a Luau fn as a cached step; results dropped
	call: <A, B, C>(fn: (A, B, C) -> ...any, a: A?, b: B?, c: C?) -> (),
	-- freeze target + args into an entry for `all`
	bind: <A, B, C>(target: (A, B, C) -> ...any, a: A?, b: B?, c: C?) -> any,
	-- run entries in parallel, return each entry's first result in order
	all: (...any) -> ...any,
	-- rerun fn forever on change to any depends path seen
	watch: (fn: lxit_task_fn, ...any) -> (),

	-- declare current node's inputs (paths or globs)
	depends: (...string) -> (),
	-- declare current node's outputs (creates parent dirs)
	outputs: (...string) -> (),
	-- download step
	fetch: (url: string, path: string) -> (),

	-- read env (.env over process env); no default = required
	env: {
		string: (name: string, default: string?) -> string,
		number: (name: string, default: number?) -> number,
		bool: (name: string, default: boolean?) -> boolean,
	},

	flags: {
		force: boolean,
		dry_run: boolean,
		assume_yes: boolean,
		args: { string },
	},
}
