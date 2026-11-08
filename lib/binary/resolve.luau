local io = require '@std/io'
local task = require '@lute/task'

local flags = require '../flags'
local install = require './install'
local ref = require './ref'
local storage = require './storage'

-- vars
local POLL_SECONDS = 0.05
local GREEN = '\27[32m'
local RED = '\27[31m'
local YELLOW = '\27[33m'
local RESET = '\27[0m'
local DIM = '\27[2m'

type missing_choice = { kind: 'install' } | { kind: 'abort' } | { kind: 'use', version: string }
type ref = ref.ref

-- picks last for this process only; nothing is persisted
local resolved: { [string]: string } = {}
local resolving: { [string]: true } = {}
local prompting = false

-- prompt
local function await_read_answer(): string
	while prompting do
		task.wait(POLL_SECONDS)
	end

	prompting = true
	local ok, answer = pcall(io.input, '> ')
	prompting = false

	if not ok then error(answer, 0) end
	return answer
end

-- install/abort first, then every installed version, newest first
local function await_prompt_missing(target: ref, installed: { string }): missing_choice
	-- the tree is already flushed: resolution only runs inside a live step
	if flags.assume_yes then return { kind = 'install' } end

	print(`{YELLOW}{target.id} is not installed{RESET}`)
	print(`  {GREEN}[i] install from GitHub{RESET}`)
	print(`  {RED}[a] abort{RESET}`)
	for i, version in installed do
		print(`  [{i}] use installed {version}`)
	end

	local answer = await_read_answer():lower():match '%w+'
	local picked = installed[tonumber(answer) or 0]
	local choice: missing_choice = if answer == 'i'
		then { kind = 'install' }
		elseif picked then { kind = 'use', version = picked }
		else { kind = 'abort' }

	-- cursor up over header + install + abort + versions + answer line, erase; sent through print to stay ordered
	local clear = `\27[{4 + #installed}F\27[J`
	local repo = `{target.owner}/{target.repo}`
	print(
		if choice.kind == 'use'
			then `{clear}{DIM}  using installed {repo}@{choice.version}{RESET}`
			elseif choice.kind == 'install' then `{clear}{DIM}  installing {target.id} from GitHub{RESET}`
			else `{clear}{RED}  aborted {target.id}{RESET}`
	)
	return choice
end

-- locate
local function await_handle_missing(target: ref, token: string?): string
	local installed = storage.await_list_installed(target)
	local choice = await_prompt_missing(target, installed)
	if choice.kind == 'install' then return install.await_install(target, token) end
	if choice.kind == 'abort' then error(`{target.id} is not installed (rerun and pick install, or pass --yes)`, 0) end

	return storage.await_find_installed(target, choice.version)
		or error(`{target.id}: installed {choice.version} has no executable`, 0)
end

local function await_locate_bin(target: ref, token: string?): string
	local version = target.version or storage.await_find_newest(target)
	local installed = version and storage.await_find_installed(target, version)
	if installed then return installed end

	return await_handle_missing(target, token)
end

local function await_resolve_bin(target: ref, token: string?): string
	while resolving[target.id] do
		task.wait(POLL_SECONDS)
	end

	local cached = resolved[target.id]
	if cached then return cached end

	resolving[target.id] = true
	local ok, path = pcall(await_locate_bin, target, token)
	resolving[target.id] = nil

	if not ok then error(path, 0) end
	resolved[target.id] = path
	return path
end

-- module
return table.freeze {
	await_resolve_bin = await_resolve_bin,
}
