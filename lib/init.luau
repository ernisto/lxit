local bin = require '@self/binary'
local env = require './utils/env'
local flags = require '@self/flags'
local fs = require '@std/fs'
local net = require '@std/net'
local print_task = require '@self/print_task'
local task = require '@lute/task'
local task_graph = require '@self/task_graph'
local watch = require '@self/watch'

-- vars
local POLL_SECONDS = 0.05

export type env = env.values
export type args = bin.args
export type cmd<A> = bin.cmd<A>
export type task_fn = task_graph.task_fn

local bound: { [any]: true } = setmetatable({}, { __mode = 'k' }) :: any

-- run
local function run(target: any, ...: any): ...any
	if not bin.is_bin(target) then return task_graph.await_task(target, ...) end

	bin.await_exec(target, ...)
	return nil
end

-- a cached step, unlike run(fn) which opens a task node; results are dropped since a fresh step skips fn
local function call(fn: task_graph.task_fn, ...: any)
	local args = table.pack(...)
	local text = print_task.describe_call(debug.info(fn, 'n') or 'fn', ...)

	task_graph.await_step(text, text, function()
		fn(table.unpack(args, 1, args.n))
	end)
end

local function fetch(url: string, path: string)
	task_graph.await_step(url, `GET {url}`, function()
		local response = net.request(url)
		assert(response.ok, `GET {url} -> {response.status}`)

		fs.writeStringToFile(path, response.body)
	end)
end

local function bind(target: any, ...: any): any
	local entry = table.freeze { target, ... }
	bound[entry] = true
	return entry
end

local function all(...: any): ...any
	local entries = { ... }
	local results = {}
	local pending = #entries
	local failure: string?

	for i, entry in entries do
		local packed = if bound[entry] then entry else { entry }

		task_graph.spawn_branch(function()
			local ok, result = pcall(run, table.unpack(packed))
			if ok then results[i] = result end

			if not ok and not failure then failure = tostring(result) end
			pending -= 1
		end)
	end

	while pending > 0 do
		task.wait(POLL_SECONDS)
	end

	if failure then error(failure, 0) end
	return table.unpack(results, 1, #entries)
end

-- module
return table.freeze {
	bin = bin.bin,
	all = all,
	run = (run :: any) :: <A, B, C, R...>(target: (A, B, C) -> R..., a: A?, b: B?, c: C?) -> R...,
	call = (call :: any) :: <A, B, C>(fn: (A, B, C) -> ...any, a: A?, b: B?, c: C?) -> (),
	bind = (bind :: any) :: <A, B, C>(target: (A, B, C) -> ...any, a: A?, b: B?, c: C?) -> any,
	depends = task_graph.depends,
	outputs = task_graph.await_outputs,
	fetch = fetch,
	watch = watch,
	env = table.freeze { string = env.string, number = env.number, bool = env.bool },
	flags = flags,
}
