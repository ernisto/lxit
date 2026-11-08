local process = require '@std/process'

local env = require '../utils/env'
local ref = require '@self/ref'
local resolve = require '@self/resolve'
local task_graph = require './task_graph'

-- vars
type child_env = env.values
export type args = { [any]: any }
export type cmd<A> = (args: A?, env: child_env?) -> ()
type bin = { [string]: bin }

local argv_of: { [bin]: { string } } = setmetatable({}, { __mode = 'k' }) :: any
local spec_of: { [bin]: ref.ref } = setmetatable({}, { __mode = 'k' }) :: any
local bins_by_id: { [string]: bin } = {}

-- argv
local function add_flag(argv: { string }, key: string, value: any)
	local name = key:gsub('_', '-')
	local flag = if #name == 1 then `-{name}` else `--{name}`

	if value == true then return table.insert(argv, flag) end
	local values = if type(value) == 'table' then value else { value }

	for _, item in values do
		table.insert(argv, flag)
		table.insert(argv, tostring(item))
	end
end

local function to_argv(prefix: { string }, args: args?): { string }
	local argv = table.clone(prefix)

	local list = (args or {}) :: { [any]: any }
	local keys = {}
	for key, value in list do
		if type(key) == 'string' and value ~= false then table.insert(keys, key) end
	end
	table.sort(keys)

	for _, key in keys do
		add_flag(argv, key, list[key])
	end
	for i = 1, #list do
		table.insert(argv, tostring(list[i]))
	end

	return argv
end

-- exec
local function await_exec(target: bin, args: args?, extra_env: child_env?)
	local target_spec = spec_of[target]
	local argv = to_argv(argv_of[target], args)
	local text = table.concat(argv, ' ')

	task_graph.await_step(`{target_spec.id} {text}`, `{target_spec.repo} {text}`, function()
		local base_env = env.await_values()
		local child_env = table.clone(base_env)
		for key, value in extra_env or {} :: child_env do
			child_env[key] = value
		end

		local command = { resolve.await_resolve_bin(target_spec, base_env.GITHUB_TOKEN), table.unpack(argv) }
		local result = process.run(command, { stdio = 'inherit', env = child_env })
		assert(result.ok, `{target_spec.repo} exited with {result.exitcode}`)
	end)
end

-- bins
local make_bin: (spec: ref.ref, argv: { string }) -> bin

local bin_meta = table.freeze {
	__call = await_exec,
	__index = function(self: bin, sub: string): bin
		local argv = table.clone(argv_of[self])
		table.insert(argv, sub)
		return make_bin(spec_of[self], argv)
	end,
}

function make_bin(spec: ref.ref, argv: { string }): bin
	local new = setmetatable({}, bin_meta) :: any
	spec_of[new] = spec
	argv_of[new] = argv
	return new
end

local function bin(id: string): any
	local cached = bins_by_id[id]
	if cached then return cached end

	local new = make_bin(ref.parse(id), {})
	bins_by_id[id] = new
	return new
end

local function is_bin(value: any): boolean
	return argv_of[value] ~= nil
end

-- module
return table.freeze {
	bin = bin,
	is_bin = is_bin,
	await_exec = await_exec,
}
