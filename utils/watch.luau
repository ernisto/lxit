local fs = require '@std/fs'
local lute_fs = require '@lute/fs'

local glob = require './glob'

-- fs.watch is non-recursive: callers add every dir they care about; a glob filter limits which entries count

-- vars
type entry = { handle: lute_fs.WatchHandle, globs: { string }, all: boolean, file: boolean }
-- mtimes: last seen per file, so access-time bumps (reported as changes on Windows) are ignored
export type watcher = { entries: { [string]: entry }, mtimes: { [string]: number? }, on_change: () -> () }

-- functions
local function new(on_change: () -> ()): watcher
	return { entries = {}, mtimes = {}, on_change = on_change }
end

local function await_mtime(path: string): number?
	return if fs.exists(path) then fs.metadata(path).modified:toSeconds() else nil
end

-- false when only metadata like the access time changed
local function await_record_mtime(watcher: watcher, path: string): boolean
	local mtime = await_mtime(path)
	local moved = watcher.mtimes[path] ~= mtime
	watcher.mtimes[path] = mtime
	return moved
end

-- a deleted dir's handle is dead: close it and its subdirs' so a recreated dir counts as new
local function drop(watcher: watcher, path: string)
	local prefix = `{path}/`
	for key, entry in watcher.entries do
		if key ~= path and key:sub(1, #prefix) ~= prefix then continue end

		watcher.entries[key] = nil
		entry.handle:close()
	end
end

local function await_notify(watcher: watcher, path: string, entry: entry, name: string, event: lute_fs.WatchEvent)
	if watcher.entries[path] ~= entry then return end
	if not fs.exists(path) then
		drop(watcher, path)
		return watcher.on_change()
	end

	local changed = if entry.file then path else `{path}/{name}`
	local moved = await_record_mtime(watcher, changed)
	if not event.rename and not moved then return end
	if watcher.entries[changed] and not fs.exists(changed) then drop(watcher, changed) end
	if entry.all then return watcher.on_change() end

	-- a new dir may hold future matches; the caller must see it to add it
	local is_new_dir = not watcher.entries[changed] and fs.exists(changed) and fs.metadata(changed).type == 'dir'
	if is_new_dir then return watcher.on_change() end

	for _, pattern in entry.globs do
		if glob.match(pattern, changed) then return watcher.on_change() end
	end
end

local function await_add(watcher: watcher, path: string, filter: string?)
	if not fs.exists(path) then return end

	local entry = watcher.entries[path]
	if not entry then
		local file = fs.metadata(path).type ~= 'dir'
		local created: entry = { globs = {}, all = false, file = file } :: any
		created.handle = lute_fs.watch(path, function(name, event)
			await_notify(watcher, path, created, name, event)
		end)

		await_record_mtime(watcher, path)
		local children = if file then {} else fs.listDirectory(path)

		for _, child in children :: any do
			await_record_mtime(watcher, `{path}/{child.name}`)
		end
		watcher.entries[path] = created
		entry = created
	end

	if not filter then
		entry.all = true
	elseif not table.find(entry.globs, filter) then
		table.insert(entry.globs, filter)
	end
end

-- module
return table.freeze {
	new = new,
	await_add = await_add,
}
