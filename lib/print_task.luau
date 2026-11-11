local env = require '../utils/env'

-- vars
local INDENT = '  '
local CYAN = '\27[36m'
local DIM = '\27[2m'
local YELLOW = '\27[33m'
local RESET = '\27[0m'

-- only what printing needs; task_graph nodes fit it structurally
export type owner = { call: string, depth: number, parent: any }
type line = { owner: owner?, header: boolean, text: string }
export type step_status = 'fresh' | 'dry' | 'run'

local STEP_MARKS: { [step_status]: string } = table.freeze {
	fresh = `{DIM}·`,
	dry = `{YELLOW}~`,
	run = `{DIM}>`,
}

local buffers: { [thread]: { line } } = {}
local buffer_parent: { [thread]: thread } = {}
local last_owner: owner?

-- describe
local function describe(value: any): string
	return if type(value) == 'function'
		then debug.info(value, 'n') or 'fn'
		elseif type(value) == 'table' then '{...}'
		else tostring(value)
end

local function describe_call(name: string, ...: any): string
	local args = table.pack(...)
	local count = args.n
	while count > 0 and args[count] == nil do
		count -= 1
	end

	local parts = {}
	for i = 1, count do
		table.insert(parts, describe(args[i]))
	end

	return `{name}({table.concat(parts, ', ')})`
end

-- lines
local function is_within(inner: owner?, outer: owner): boolean
	local cursor = inner
	while cursor do
		if cursor == outer then return true end
		cursor = cursor.parent
	end
	return false
end

local function write_line(line: line)
	-- parallel branches interleave, so re-print the header the line hangs under when context was lost
	local anchor = if line.header and line.owner then line.owner.parent else line.owner
	if anchor and not is_within(last_owner, anchor) then
		print(env.redact(`{string.rep(INDENT, anchor.depth)}{CYAN}{anchor.call} …{RESET}`))
	end

	print(env.redact(line.text))
	last_owner = line.owner
end

local function emit(line: line)
	local buffer = buffers[coroutine.running()]
	if buffer then return table.insert(buffer, line) end
	write_line(line)
end

-- buffers
local function start_buffer(thread: thread, parent: thread)
	buffers[thread] = {}
	buffer_parent[thread] = parent
end

local function end_buffer(thread: thread)
	local lines = buffers[thread]
	local parent_buffer = buffers[buffer_parent[thread]]
	buffers[thread] = nil
	buffer_parent[thread] = nil

	for _, line in lines do
		if parent_buffer then
			table.insert(parent_buffer, line)
		else
			write_line(line)
		end
	end
end

local function flush_buffers(thread: thread)
	local parent = buffer_parent[thread]
	if parent then flush_buffers(parent) end

	local lines = buffers[thread]
	if not lines then return end

	for _, line in lines do
		write_line(line)
	end
	table.clear(lines)
end

-- print
local function print_header(node: owner)
	emit { owner = node, header = true, text = `{string.rep(INDENT, node.depth)}{CYAN}{node.call}{RESET}` }
end

local function print_step(node: owner?, status: step_status, label: string)
	local depth = if node then node.depth + 1 else 0
	emit { owner = node, header = false, text = `{string.rep(INDENT, depth)}{STEP_MARKS[status]} {label}{RESET}` }

	-- a live step's own output (or prompt) must land after everything above it
	if status == 'run' then flush_buffers(coroutine.running()) end
end

-- module
return table.freeze {
	describe_call = describe_call,
	print_header = print_header,
	print_step = print_step,
	start_buffer = start_buffer,
	end_buffer = end_buffer,
	flush_buffers = flush_buffers,
}
