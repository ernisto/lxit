-- vars
type version = { core: { number }, pre: string? }

-- functions
local function parse(text: string): version
	local core_text, pre = text:match '^v?([%d%.]+)%-?([^+]*)'
	local core = {}

	for part in (core_text or ''):gmatch '%d+' do
		table.insert(core, tonumber(part) :: number)
	end
	return { core = core, pre = if pre and pre ~= '' then pre else nil }
end

local function compare_pre(a: string, b: string): number
	local a_parts, b_parts = a:split '.', b:split '.'
	for i = 1, math.max(#a_parts, #b_parts) do
		local left, right = a_parts[i], b_parts[i]
		if left == right then continue end

		if not left then return -1 end
		if not right then return 1 end

		local left_number, right_number = tonumber(left), tonumber(right)
		if left_number and right_number then return if left_number < right_number then -1 else 1 end

		return if left < right then -1 else 1
	end
	return 0
end

-- semver order (prerelease < release, +build ignored); -1 | 0 | 1
local function compare(a: string, b: string): number
	local left, right = parse(a), parse(b)
	for i = 1, math.max(#left.core, #right.core) do
		local l, r = left.core[i] or 0, right.core[i] or 0
		if l ~= r then return if l < r then -1 else 1 end
	end

	if left.pre == right.pre then return 0 end
	if not left.pre then return 1 end
	if not right.pre then return -1 end
	return compare_pre(left.pre, right.pre)
end

-- module
return table.freeze { compare = compare }
