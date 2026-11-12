local env = require '../utils/env'

-- vars
local INDENT = '  '
local WHITE = '\27[37m'
local DIM = '\27[2m'
local YELLOW = '\27[33m'
local GREEN = '\27[32m'
local RED = '\27[31m'
local RESET = '\27[0m'

-- only what printing needs; task_graph nodes fit it structurally
export type owner = { call: string, depth: number, parent: any }
type line = { owner: owner?, header: boolean, close: boolean?, text: string? }
export type step_status = 'fresh' | 'dry' | 'run'
export type outcome = 'done' | 'failed'

local STEP_MARKS: { [step_status]: string } = table.freeze {
	fresh = `{DIM}·`,
	dry = `{YELLOW}~{WHITE}`,
	run = `{WHITE}>`,
}

-- printed headers -> whether drawn fresh, or 'pending' while freshness is undecided
local headers: { [owner]: boolean | 'pending' } = setmetatable({}, { __mode = 'k' }) :: any
-- topmost undecided node -> written lines waiting on its freshness
local held: { [owner]: { line } } = {}
-- headers already on screen
local written: { [owner]: true } = setmetatable({}, { __mode = 'k' }) :: any
-- finished tasks; a header drawn after its task finished already shows the outcome
local outcomes: { [owner]: outcome } = setmetatable({}, { __mode = 'k' }) :: any
local drawn_final: { [owner]: true } = setmetatable({}, { __mode = 'k' }) :: any
-- errors already printed under their failed step
local reported: { [any]: true } = {}

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
local function header_text(node: owner, suffix: string): string
	local outcome = outcomes[node]
	local style = if outcome == 'failed'
		then `{RED}✗`
		elseif outcome == 'done' then `{GREEN}✓`
		elseif headers[node] == true then `{DIM}·`
		else `{YELLOW}~`
	return `{string.rep(INDENT, node.depth)}{style} {node.call}{suffix}{RESET}`
end

local function is_within(inner: owner?, outer: owner): boolean
	local cursor = inner
	while cursor do
		if cursor == outer then return true end
		cursor = cursor.parent
	end
	return false
end

local function topmost_pending(owner: owner?): owner?
	local found
	local cursor = owner
	while cursor do
		if headers[cursor] == 'pending' then found = cursor end
		cursor = cursor.parent
	end
	return found
end

-- headers draw when the first line under them hits the screen, so a buffered branch can't print them out of order
local function draw_header(node: owner)
	if written[node] then return end
	if node.parent then draw_header(node.parent) end

	written[node] = true
	if outcomes[node] then drawn_final[node] = true end
	print(env.redact(header_text(node, '')))
end

-- the header is already on screen with a running mark, so the outcome gets its own line
local function write_close(node: owner)
	-- a failure already shows on its step, so the header turns red only when drawn late
	if outcomes[node] ~= 'done' or drawn_final[node] or not written[node] then return end

	local parent = node.parent
	if parent and not is_within(last_owner, parent) then print(env.redact(header_text(parent, ' …'))) end
	print(env.redact(header_text(node, '')))
	last_owner = node
end

local function write_line(line: line)
	local holder = topmost_pending(line.owner)
	if holder then
		held[holder] = held[holder] or {}
		return table.insert(held[holder], line)
	end

	local owner = line.owner
	if line.close and owner then return write_close(owner) end

	-- a fresh task hides its fresh children; a stale one below still draws the path to it
	if line.header and owner and headers[owner] == true and owner.parent and headers[owner.parent] == true then
		return
	end

	local anchor = owner
	while anchor and not written[anchor] do
		anchor = anchor.parent
	end
	if line.header and anchor == owner then return end

	-- parallel branches interleave, so re-print the header the line hangs under when context was lost
	if anchor and not is_within(last_owner, anchor) then print(env.redact(header_text(anchor, ' …'))) end
	if owner then draw_header(owner) end
	if not line.header then print(env.redact(line.text :: string)) end
	last_owner = owner
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
local function resolve(node: owner, fresh: boolean)
	headers[node] = fresh
	local lines = held[node]
	held[node] = nil
	for _, line in lines or {} do
		write_line(line)
	end
end

-- a live step can't wait: its ancestors resolve now, and since it runs they end stale anyway
local function resolve_ancestors(node: owner?)
	local holder = topmost_pending(node)
	while holder do
		resolve(holder, false)
		holder = topmost_pending(node)
	end
end

-- lazy, idempotent; ancestors first; fresh = nil queues the header until its node decides (lines under it wait)
local function print_header(node: owner, fresh: boolean?)
	local drawn = headers[node]
	if drawn ~= nil then
		if drawn == 'pending' and fresh ~= nil then resolve(node, fresh) end
		return
	end
	if node.parent then print_header(node.parent) end

	headers[node] = if fresh == nil then 'pending' else fresh
	emit { owner = node, header = true }
end

local function print_step(node: owner?, status: step_status, label: string)
	if node then
		print_header(node)
		-- a fresh task hides its steps
		if status == 'fresh' and headers[node] == true then return end
	end

	local depth = if node then node.depth + 1 else 0
	emit { owner = node, header = false, text = `{string.rep(INDENT, depth)}{STEP_MARKS[status]} {label}{RESET}` }

	-- a live step's own output (or prompt) must land after everything above it
	if status ~= 'run' then return end
	flush_buffers(coroutine.running())
	resolve_ancestors(node)
end

local function print_failure(node: owner?, label: string, err: any)
	local indent = string.rep(INDENT, if node then node.depth + 1 else 0)
	emit { owner = node, header = false, text = `{indent}{RED}✗ {label}{RESET}` }
	for message in tostring(err):gmatch '[^\n]+' do
		emit { owner = node, header = false, text = `{indent}{INDENT}{RED}{message}{RESET}` }
	end

	reported[err] = true
	flush_buffers(coroutine.running())
end

local function was_reported(err: any): boolean
	return reported[err] == true
end

-- nil outcome: finished without running anything (fresh, dry), keeps its mark
local function print_close(node: owner, outcome: outcome?)
	if outcome then outcomes[node] = outcome end
	print_header(node, false)
	if outcome then emit { owner = node, header = false, close = true } end
end

-- module
return table.freeze {
	describe_call = describe_call,
	print_header = print_header,
	print_close = print_close,
	print_failure = print_failure,
	was_reported = was_reported,
	print_step = print_step,
	start_buffer = start_buffer,
	end_buffer = end_buffer,
	flush_buffers = flush_buffers,
}
