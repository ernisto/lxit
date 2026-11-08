-- vars
local API = 'https://api.github.com'
local JSON = 'application/vnd.github+json'
local BINARY = 'application/octet-stream'

export type request = { url: string, method: 'GET', headers: { [string]: string } }
export type asset = { id: number, name: string }
export type release = { tag_name: string, assets: { asset } }

export type endpoint<Path, Response> = {
	base: string,
	accept: string,
	path: Path, -- sample, types `request`
	response: Response, -- sample, types the decoded body
	request: (self: endpoint<Path, Response>, token: string?, path: Path) -> request,
}

type repo_path = { owner: string, repo: string }

-- functions
local function encode(text: string): string
	return (text:gsub('[^%w%-%._~]', function(char)
		return string.format('%%%02X', string.byte(char))
	end))
end

local function build(endpoint: endpoint<any, any>, token: string?, path: { [string]: any }): request
	local url = endpoint.base:gsub('{([%w_]+)}', function(name)
		local value = path[name]
		return if value ~= nil
			then encode(tostring(value))
			else error(`missing path parameter '{name}' for {endpoint.base}`)
	end)

	local headers = { ['User-Agent'] = 'lxit', Accept = endpoint.accept }
	if token then headers.Authorization = `Bearer {token}` end

	return { url = url, method = 'GET', headers = headers }
end

local function endpoint<Path, Response>(def: { base: string, accept: string, path: Path, response: Response }): endpoint<Path, Response>
	local full = def :: any
	full.request = build
	return table.freeze(full)
end

-- module
return table.freeze {
	latest_release = endpoint {
		base = API .. '/repos/{owner}/{repo}/releases/latest',
		accept = JSON,
		path = {} :: repo_path,
		response = {} :: release,
	},
	release_by_tag = endpoint {
		base = API .. '/repos/{owner}/{repo}/releases/tags/{tag}',
		accept = JSON,
		path = {} :: repo_path & { tag: string },
		response = {} :: release,
	},
	-- redirects to the asset bytes
	download_asset = endpoint {
		base = API .. '/repos/{owner}/{repo}/releases/assets/{asset_id}',
		accept = BINARY,
		path = {} :: repo_path & { asset_id: number },
		response = '',
	},
}
