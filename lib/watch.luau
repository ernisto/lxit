local env = require '../utils/env'
local flags = require './flags'
local print_task = require './print_task'
local task = require '@lute/task'
local task_graph = require './task_graph'
local watcher = require '../utils/watch'

-- vars
local WATCH_SECONDS = 0.2
local RED = '\27[31m'
local RESET = '\27[0m'

-- functions
-- outputs get rewritten by the reruns themselves; watching them loops forever
local function is_produced(path: string): boolean
	for output in task_graph.produced do
		if path == output or path:sub(1, #output + 1) == `{output}/` then return true end
	end
	return false
end

local function await_watch_new_paths(observer: watcher.watcher)
	for _, target in task_graph.watched do
		if is_produced(target.path) then continue end
		watcher.await_add(observer, target.path, target.glob)
	end
end

local function await_watch(fn: task_graph.task_fn, ...: any)
	local args = table.pack(...)
	if flags.dry_run then return task_graph.await_task(fn, table.unpack(args, 1, args.n)) end

	local changed = true
	local observer = watcher.new(function()
		changed = true
	end)

	while true do
		task.wait(WATCH_SECONDS)

		if not changed then continue end
		changed = false

		local ok, err = pcall(task_graph.await_task, fn, table.unpack(args, 1, args.n))
		-- fresh reruns never hit a `run` step, so nothing else flushes this branch
		print_task.flush_buffers(coroutine.running())
		if not ok and not print_task.was_reported(err) then print(env.redact(`{RED}{err}{RESET}`)) end

		await_watch_new_paths(observer)
	end
end

-- module
return await_watch
