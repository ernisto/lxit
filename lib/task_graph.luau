local fs = require '@std/fs'
local task = require '@lute/task'

local flags = require './flags'
local glob = require '../utils/glob'
local print_task = require './print_task'

-- vars
local POLL_SECONDS = 0.05

export type task_fn = (...any) -> ...any

type stale = { kind: 'stale', key: string, signature: string, newest: number }
type decision = { kind: 'pending' } | { kind: 'uncached' } | { kind: 'fresh', key: string } | stale

-- what watch mode should observe: a path, optionally filtered to a glob's matches
type watch_target = { path: string, glob: string? }

export type node = {
	name: string,
	call: string,
	parent: node?,
	depth: number,
	depends: { string },
	outputs: { string },
	dirty: boolean,
	decision: decision,
}

local running: { [string]: true } = {}
local current: { [thread]: node? } = {}
local watched: { [string]: watch_target } = {}
-- paths some node outputs: watch mode skips them, their depends are watched instead
local produced: { [string]: true } = {}
-- runs of this process only (watch reruns, argv changes); nothing is persisted
local runs: { [string]: { newest: number, signature: string } } = {}

-- freshness
local function watch_path(path: string, pattern: string?)
	watched[`{path}|{pattern or ''}`] = { path = path, glob = pattern }
end

local function await_scan_mtime(path: string, watch_dirs: boolean): number
	local meta = fs.metadata(path)
	if meta.type ~= 'dir' then return meta.modified:toSeconds() end

	if watch_dirs then watch_path(path) end
	local newest = meta.modified:toSeconds()
	for _, entry in fs.listDirectory(path) do
		newest = math.max(newest, await_scan_mtime(`{path}/{entry.name}`, watch_dirs))
	end

	return newest
end

-- ponytail: a deleted match lowers nothing, so deletions alone don't make a node stale
local function await_scan_glob(pattern: string): number
	local files, dirs = glob.await_expand(pattern)
	for _, dir in dirs do
		watch_path(dir, pattern)
	end

	local newest = 0
	for _, file in files do
		newest = math.max(newest, fs.metadata(file).modified:toSeconds())
	end
	return newest
end

local function await_scan_depends(node: node): number
	local newest = 0
	for _, path in node.depends do
		if glob.is_glob(path) then
			newest = math.max(newest, await_scan_glob(path))
			continue
		end

		local exists = fs.exists(path)
		-- dry run never produces outputs, so a sibling's missing output means stale, not a bug
		if flags.dry_run and not exists then return math.huge end

		assert(exists, `{node.name} depends on missing path: {path}`)
		watch_path(path)
		newest = math.max(newest, await_scan_mtime(path, true))
	end
	return newest
end

-- oldest of the outputs' newest mtimes; nil when any output is missing
local function await_scan_outputs(node: node): number?
	local oldest = math.huge
	for _, path in node.outputs do
		if not fs.exists(path) then return nil end
		oldest = math.min(oldest, await_scan_mtime(path, false))
	end
	return oldest
end

local function await_check_fresh(node: node, stale: stale): boolean
	if flags.force or node.dirty then return false end

	local oldest = await_scan_outputs(node)
	if not oldest then return false end

	-- ran earlier in this process: fresh while no depend got newer than what that run saw
	local last = runs[stale.key]
	if last then return last.signature == stale.signature and stale.newest <= last.newest end

	-- make-style: every output newer than every depend; no outputs means nothing proves freshness
	return #node.outputs > 0 and stale.newest <= oldest
end

local function await_decide(node: node, signature: string)
	local targets = if #node.outputs > 0 then node.outputs else node.depends
	if #targets == 0 then
		node.decision = { kind = 'uncached' }
		return
	end

	local key = `{node.name}:{table.concat(targets, ',')}`
	while running[key] do
		task.wait(POLL_SECONDS)
	end
	running[key] = true

	local stale: stale = { kind = 'stale', key = key, signature = signature, newest = await_scan_depends(node) }
	node.decision = if await_check_fresh(node, stale) then { kind = 'fresh', key = key } else stale
end

local function await_step(signature: string, label: string, perform: () -> ())
	local node = current[coroutine.running()]
	if node and node.decision.kind == 'pending' then await_decide(node, signature) end
	if node then print_task.print_header(node, node.decision.kind == 'fresh') end

	if node and node.decision.kind == 'fresh' then return print_task.print_step(node, 'fresh', label) end
	if flags.dry_run then return print_task.print_step(node, 'dry', label) end

	print_task.print_step(node, 'run', label)
	local ok, err = pcall(perform)
	if ok then return end

	print_task.print_failure(node, label, err)
	error(err, 0)
end

-- nodes
local function release_node(node: node)
	local decision = node.decision
	if decision.kind == 'fresh' or decision.kind == 'stale' then running[decision.key] = nil end
end

local function mark_ancestors_dirty(node: node)
	local ancestor = node.parent
	while ancestor do
		ancestor.dirty = true
		ancestor = ancestor.parent
	end
end

local function close_node(node: node)
	release_node(node)
	local ran = node.decision.kind ~= 'fresh' and not flags.dry_run
	print_task.print_close(node, if ran then 'done' else nil)
	-- a node doing its work inline (no step) never decides; still watch its depends
	if node.decision.kind == 'pending' and not flags.dry_run then await_scan_depends(node) end

	local decision = node.decision
	if decision.kind ~= 'stale' then return end

	if #node.outputs > 0 then mark_ancestors_dirty(node) end
	if flags.dry_run then return end

	runs[decision.key] = { newest = decision.newest, signature = decision.signature }
end

local function await_task(fn: task_fn, ...: any): ...any
	local thread = coroutine.running()
	local parent = current[thread]
	local name = debug.info(fn, 'n') or error('x.run task must be a named function', 3)
	local node: node = {
		name = name,
		call = print_task.describe_call(name, ...),
		parent = parent,
		depth = if parent then parent.depth + 1 else 0,
		depends = {},
		outputs = {},
		dirty = false,
		decision = { kind = 'pending' },
	}
	current[thread] = node

	local results = table.pack(pcall(fn, ...))
	current[thread] = node.parent

	if not results[1] then
		release_node(node)
		print_task.print_close(node, 'failed')
		error(results[2], 0)
	end

	close_node(node)
	return table.unpack(results, 2, results.n)
end

local function get_node(): node
	return current[coroutine.running()] or error('x.depends/x.outputs must be called inside x.run', 3)
end

local function depends(...: string)
	local node = get_node()
	for _, path in { ... } do
		table.insert(node.depends, path)
	end
end

-- per segment: parallel branches may create the same parent between exists and mkdir
local function await_make_dirs(dir: string)
	local prefix = ''
	for segment in dir:gmatch '[^/]+' do
		prefix = if prefix == '' then segment else `{prefix}/{segment}`
		if fs.exists(prefix) then continue end

		local ok, err = pcall(fs.createDirectory :: any, prefix)
		if not ok and not fs.exists(prefix) then error(err, 0) end
	end
end

local function await_outputs(...: string)
	local node = get_node()
	for _, path in { ... } do
		table.insert(node.outputs, path)
		produced[path] = true

		local parent = path:match '^(.+)/[^/]+$'
		if parent and not flags.dry_run then await_make_dirs(parent) end
	end
end

-- branches
local function spawn_branch(body: () -> ())
	local parent_thread = coroutine.running()
	local parent = current[parent_thread]

	task.spawn(function()
		local child = coroutine.running()
		current[child] = parent
		print_task.start_buffer(child, parent_thread)

		body()
		print_task.end_buffer(child)
		current[child] = nil
	end)
end

-- module
return table.freeze {
	watched = watched,
	produced = produced,
	await_step = await_step,
	await_task = await_task,
	depends = depends,
	await_outputs = await_outputs,
	spawn_branch = spawn_branch,
}
