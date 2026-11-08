local fs = require '@std/fs'
local process = require '@std/process'
local system = require '@std/system'

local ref = require './ref'
local version = require '../../utils/version'

-- vars
local HOME = process.env.USERPROFILE or process.env.HOME or error 'neither USERPROFILE nor HOME is set'
local STORAGE_DIR = `{HOME}/.rokit/tool-storage`
local EXE = if system.win32 then '.exe' else ''

type ref = ref.ref

-- names
local function exe_name(repo: string): string
	return `{repo:lower()}{EXE}`
end

-- with no extension to look for, only the exact name counts
local function is_exe(name: string): boolean
	return EXE ~= '' and name:lower():sub(-#EXE) == EXE
end

-- lookup
local function tool_dir(target: ref): string
	return `{STORAGE_DIR}/{target.owner:lower()}/{target.repo:lower()}`
end

local function await_find_exe(dir: string, repo: string): string?
	local preferred = `{dir}/{exe_name(repo)}`
	if fs.exists(preferred) then return preferred end

	for _, entry in fs.listDirectory(dir) do
		if entry.type == 'file' and is_exe(entry.name) then return `{dir}/{entry.name}` end
	end
	return nil
end

-- newest first
local function await_list_installed(target: ref): { string }
	local dir = tool_dir(target)
	if not fs.exists(dir) then return {} end

	local versions = {}
	for _, entry in fs.listDirectory(dir) do
		if entry.type == 'dir' then table.insert(versions, entry.name) end
	end
	table.sort(versions, function(a, b)
		return version.compare(a, b) > 0
	end)
	return versions
end

local function await_find_installed(target: ref, installed_version: string): string?
	local dir = `{tool_dir(target)}/{installed_version}`
	return fs.exists(dir) and await_find_exe(dir, target.repo) or nil
end

local function await_find_newest(target: ref): string?
	return await_list_installed(target)[1]
end

-- store
local function await_store(target: ref, store_version: string, contents: string): string
	local dir = `{tool_dir(target)}/{store_version}`
	local path = `{dir}/{exe_name(target.repo)}`

	fs.createDirectory(dir, { makeParents = true })
	fs.writeStringToFile(path, contents)

	if system.win32 then return path end

	local result = process.run { 'chmod', '+x', path }
	assert(result.ok, `chmod +x {path} exited with {result.exitcode}`)
	return path
end

-- module
return table.freeze {
	exe_name = exe_name,
	is_exe = is_exe,
	await_find_installed = await_find_installed,
	await_find_newest = await_find_newest,
	await_list_installed = await_list_installed,
	await_store = await_store,
}
