local fs = require '@std/fs'

-- globs over `/` paths: `*` and `?` stay inside one segment, `**` spans segments, `{a,b}` alternates

-- vars
local MAGIC = '[%*%?{]'

-- functions
local function is_glob(text: string): boolean
	return text:find(MAGIC) ~= nil
end

local function expand_braces(pattern: string): { string }
	local before, options, after = pattern:match '^(.-){([^{}]*)}(.*)$'
	if not before or not options or not after then return { pattern } end

	local expanded = {}
	for option in (options .. ','):gmatch '([^,]*),' do
		for _, variant in expand_braces(before .. option .. after) do
			table.insert(expanded, variant)
		end
	end
	return expanded
end

local function segment_pattern(segment: string): string
	local escaped = segment:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%0')
	return '^' .. escaped:gsub('%*', '[^/]*'):gsub('%?', '[^/]') .. '$'
end

local function match_parts(pattern: { string }, i: number, path: { string }, j: number): boolean
	if i > #pattern then return j > #path end

	if pattern[i] == '**' then
		for k = j, #path + 1 do
			if match_parts(pattern, i + 1, path, k) then return true end
		end
		return false
	end

	if j > #path then return false end
	return path[j]:find(segment_pattern(pattern[i])) ~= nil and match_parts(pattern, i + 1, path, j + 1)
end

local function match(pattern: string, path: string): boolean
	local parts = path:gsub('\\', '/'):split '/'
	for _, variant in expand_braces(pattern) do
		if match_parts(variant:split '/', 1, parts, 1) then return true end
	end
	return false
end

-- longest leading run of plain segments: the dir every match lives under
local function base(pattern: string): string
	local plain = {}
	for _, segment in pattern:split '/' do
		if is_glob(segment) then break end
		table.insert(plain, segment)
	end
	return if #plain > 0 then table.concat(plain, '/') else '.'
end

-- ponytail: walks the whole base subtree even when the pattern has no `**`; prune by depth if that gets slow
local function await_walk(pattern: string, path: string, files: { string }, dirs: { string })
	if fs.metadata(path).type ~= 'dir' then
		if match(pattern, path) then table.insert(files, path) end
		return
	end

	table.insert(dirs, path)
	for _, entry in fs.listDirectory(path) do
		await_walk(pattern, if path == '.' then entry.name else `{path}/{entry.name}`, files, dirs)
	end
end

-- matching files plus every dir walked (to watch for new matches)
local function await_expand(pattern: string): ({ string }, { string })
	local files, dirs = {}, {}
	for _, variant in expand_braces(pattern) do
		local root = base(variant)
		if fs.exists(root) then await_walk(variant, root, files, dirs) end
	end
	return files, dirs
end

-- module
return table.freeze {
	is_glob = is_glob,
	match = match,
	await_expand = await_expand,
}
