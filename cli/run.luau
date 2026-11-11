local fs = require '@std/fs'
local luau = require '@std/luau'
local process = require '@std/process'

local analyze = require './analyze'
local env = require '../utils/env'
local x = require '../lib'

-- vars
local BOLD_YELLOW = '\27[1m\27[33m'
local GREEN = '\27[32m'
local YELLOW = '\27[33m'
local DIM = '\27[2m'
local RED = '\27[31m'
local RESET = '\27[0m'
local ENTRY = 'lxit'
local TASKS_PATH = 'tasks.luau'

type tasks = { [string]: x.task_fn }
type command = 'run' | 'watch'
type row = { label: string, args: string?, description: string }

local COMMANDS: { row } = table.freeze {
	{ label = 'run', args = ' <TASK> [ARGS]...', description = `{DIM}run a task once{RESET}` },
	{ label = 'watch', args = ' <TASK> [ARGS]...', description = `{DIM}rerun a task when its depends change{RESET}` },
}
local OPTIONS: { row } = table.freeze {
	{ label = '-y, --yes', description = `{DIM}install missing tools without asking{RESET}` },
	{ label = '-f, --force', description = `{DIM}rerun every step, ignore freshness{RESET}` },
	{ label = '    --dry-run', description = `{DIM}print the call tree, run nothing{RESET}` },
}

-- help
-- call parens green (they belong to the name), `|` and `?` dim, the rest plain
local function color_punctuation(text: string): string
	return (
		text:gsub('[()|?]', function(mark)
			return (if mark == '(' or mark == ')' then GREEN else DIM) .. mark .. RESET
		end)
	)
end

local function print_rows(title: string, rows: { row })
	local width = 0
	for _, row in rows do
		width = math.max(width, #row.label + #(row.args or ''))
	end

	print(`\n{BOLD_YELLOW}{title}:{RESET}`)
	for _, row in rows do
		local args = row.args or ''
		local padding = string.rep(' ', width - #row.label - #args)
		print(`  {GREEN}{row.label}{RESET}{color_punctuation(args)}{padding}  {row.description}`)
	end
end

local function await_env_color(var: analyze.env_var): string
	return if env.await_is_set(var.name) then DIM elseif var.optional then YELLOW else RED
end

local function await_format_env(vars: { analyze.env_var }): string
	if #vars == 0 then return '' end

	local parts = {}
	for _, var in vars do
		table.insert(parts, `{await_env_color(var)}{var.name}{if var.optional then '?' else ''}{RESET}`)
	end
	return `{DIM}(needs env: {RESET}{table.concat(parts, ' ')}{DIM}){RESET}`
end

local function format_params(params: { analyze.param }): string
	local parts = {}
	for _, param in params do
		local label = if param.choices then table.concat(param.choices, ' | ') else param.name
		table.insert(parts, `{label}{if param.optional then '?' else ''}`)
	end
	return `({table.concat(parts, ', ')})`
end

local function await_describe_task(signature: analyze.signature): string
	local parts = {}
	if signature.doc then table.insert(parts, `{DIM}{signature.doc}{RESET}`) end

	local needs = await_format_env(signature.env)
	if needs ~= '' then table.insert(parts, needs) end
	return table.concat(parts, ' ')
end

local function await_env_rows(signatures: { analyze.signature }): { row }
	local by_name: { [string]: analyze.env_var } = {}
	for _, signature in signatures do
		for _, var in signature.env do
			local seen = by_name[var.name]
			by_name[var.name] = if seen and not seen.optional then seen else var
		end
	end

	local names = {}
	for name in by_name do
		table.insert(names, name)
	end
	table.sort(names)

	local rows = {}
	for _, name in names do
		local var = by_name[name]
		local missing = if env.await_is_set(name) then '' else ` {RED}not defined{RESET}`
		table.insert(rows, { label = name, description = `{var.kind}{missing}` })
	end
	return rows
end

local function await_print_help(tasks: tasks)
	local names = {}
	for name in tasks do
		table.insert(names, name)
	end
	table.sort(names)

	local signatures = analyze.await_read_signatures(TASKS_PATH)
	local task_rows, task_signatures = {}, {}
	for _, name in names do
		local signature = signatures[name]
		local args = if signature and #signature.params > 0 then format_params(signature.params) else nil
		local description = if signature then await_describe_task(signature) else ''
		table.insert(task_rows, { label = name, args = args, description = description })
		if signature then table.insert(task_signatures, signature) end
	end

	print(`{BOLD_YELLOW}Usage:{RESET} {GREEN}{ENTRY}{RESET} [OPTIONS] <COMMAND> <TASK> [ARGS]...`)
	print_rows('Commands', COMMANDS)
	print_rows('Options', OPTIONS)
	print_rows('Env vars', await_env_rows(task_signatures))
	print_rows('Tasks', task_rows)
end

local function await_fail(tasks: tasks, message: string): never
	print(`{RED}{message}{RESET}\n`)
	await_print_help(tasks)
	process.exit(1)
	error 'unreachable'
end

-- cli
local function await_cli(tasks: tasks)
	local command, name = x.flags.args[1], x.flags.args[2]
	if not command then return await_print_help(tasks) end

	if command ~= 'run' and command ~= 'watch' then await_fail(tasks, `unknown command: {command}`) end
	if not name then await_fail(tasks, `{command} needs a task`) end

	local fn = tasks[name] or await_fail(tasks, `unknown task: {name}`)
	local args = { table.unpack(x.flags.args, 3) }

	if (command :: command) == 'watch' then return x.watch(fn, table.unpack(args)) end

	local ok, err = pcall(x.run :: any, fn, table.unpack(args))
	if ok then return end

	print(env.redact(`{RED}{err}{RESET}`))
	process.exit(1)
end

-- run
-- ponytail: lute _G is readonly, so tasks.luau is loaded with its own env; modules it requires don't see `lxit`
local tasks_env = setmetatable({ lxit = x }, { __index = _G })
await_cli(luau.load(luau.compile(fs.readFileToString(TASKS_PATH)), TASKS_PATH, tasks_env :: any)())
