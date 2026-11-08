local json = require '@std/json'
local net = require '@std/net'
local system = require '@std/system'

local github = require '../../utils/github'
local ref = require './ref'
local storage = require './storage'
local unzip = require '../../utils/unzip'

-- vars
local GREEN = '\27[32m'
local RESET = '\27[0m'

local OS_PATTERNS = if system.win32
	then { 'windows', 'win64', 'win32', '%f[%a]win%f[%A]' }
	elseif system.macos then { 'macos', 'darwin', 'apple', 'osx' }
	else { 'linux' }

local ARCH_PATTERNS: { [string]: { string } } = table.freeze {
	x86_64 = { 'x86_64', 'x64', 'amd64' },
	aarch64 = { 'aarch64', 'arm64' },
	arm64 = { 'aarch64', 'arm64' },
}

type ref = ref.ref

-- send
local function await_send(request: github.request): (boolean, string)
	local response = net.request(request.url, { method = request.method :: string, headers = request.headers })
	return response.ok, response.body
end

local function await_fetch_release(target: ref, token: string?): github.release
	local repo = { owner = target.owner, repo = target.repo }
	local requests: { github.request } = if target.version
		then {
			github.release_by_tag:request(token, { owner = repo.owner, repo = repo.repo, tag = `v{target.version}` }),
			github.release_by_tag:request(token, { owner = repo.owner, repo = repo.repo, tag = target.version }),
		}
		else { github.latest_release:request(token, repo) }

	local tried = {}
	for _, request in requests do
		local ok, body = await_send(request)
		if ok then return json.deserialize(body) :: any end
		table.insert(tried, request.url)
	end
	error(`no GitHub release for {target.id} (tried {table.concat(tried, ', ')})`, 0)
end

-- pick
local function matches_any(name: string, patterns: { string }): boolean
	for _, pattern in patterns do
		if name:find(pattern) then return true end
	end
	return false
end

local function pick_asset(target: ref, assets: { github.asset }): github.asset
	local arch_patterns = ARCH_PATTERNS[system.arch] or { system.arch }
	local fallback

	for _, asset in assets do
		local name = asset.name:lower()
		local fits_os = name:sub(-4) == '.zip' and matches_any(name, OS_PATTERNS)

		if fits_os and matches_any(name, arch_patterns) then return asset end
		if fits_os then fallback = fallback or asset end
	end
	if fallback then return fallback end

	local names = {}
	for _, asset in assets do
		table.insert(names, asset.name)
	end
	error(`no {system.os}/{system.arch} zip in {target.id} release: {table.concat(names, ', ')}`, 0)
end

-- extract
local function extract_exe(target: ref, archive: string, asset_name: string): string
	local reader = unzip.load(buffer.fromstring(archive))
	local wanted = storage.exe_name(target.repo)
	local exact, any_exe

	reader:walk(function(entry)
		if entry.isDirectory then return end

		local base = (entry.name:match '[^/]+$' or entry.name):lower()
		if base == wanted then exact = exact or entry end
		if storage.is_exe(base) then any_exe = any_exe or entry end
	end)

	local entry = exact or any_exe or error(`no {target.repo} executable inside {asset_name}`, 0)
	return reader:extract(entry, { type = 'text' }) :: string
end

-- install
local function await_install(target: ref, token: string?): string
	local release = await_fetch_release(target, token)
	local release_version = release.tag_name:gsub('^v', '')
	local asset = pick_asset(target, release.assets)

	print(`  downloading {asset.name}`)
	local asset_path = { owner = target.owner, repo = target.repo, asset_id = asset.id }
	local ok, archive = await_send(github.download_asset:request(token, asset_path))
	assert(ok, `downloading {asset.name} failed`)

	local exe_path = storage.await_store(target, release_version, extract_exe(target, archive, asset.name))
	print(`  {GREEN}installed {target.owner}/{target.repo}@{release_version}{RESET}`)
	return exe_path
end

-- module
return table.freeze {
	await_install = await_install,
}
