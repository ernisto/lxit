local fs = require '@std/fs'
local process = require '@std/process'

-- vars
export type values = { [string]: string }

local BOOLS: { [string]: boolean } = table.freeze {
	['true'] = true,
	['1'] = true,
	yes = true,
	['false'] = false,
	['0'] = false,
	no = false,
}

-- loaded on first read: modules cannot yield at require time
local values: values?
local secrets: { string } = {}

-- values
local function await_values(): values
	if values then return values end

	local loaded = table.clone(process.env)
	local source = if fs.exists '.env' then fs.readFileToString '.env' else ''
	for line in source:gmatch '[^\r\n]+' do
		local key, value = line:match '^%s*([%w_]+)%s*=%s*(.-)%s*$'
		if key and value then loaded[key] = (value:gsub('^["\'](.*)["\']$', '%1')) end
	end

	values = table.freeze(loaded)
	return loaded
end

-- typed reads; no default = required
local function await_read(name: string): string?
	local value = await_values()[name]
	return if value and value ~= '' then value else nil
end

local function await_is_set(name: string): boolean
	return await_read(name) ~= nil
end

local function missing(name: string): never
	error(`missing env var {name} (set it in .env)`, 3)
end

local function string_var(name: string, default: string?): string
	return await_read(name) or default or missing(name)
end

local function number_var(name: string, default: number?): number
	local text = await_read(name)
	if not text then return default or missing(name) end

	return tonumber(text) or error(`env var {name} is not a number: {text}`, 2)
end

local function bool_var(name: string, default: boolean?): boolean
	local text = await_read(name)
	if not text and default ~= nil then return default end
	if not text then return missing(name) end

	local value = BOOLS[text:lower()]
	return if value ~= nil then value else error(`env var {name} is not a bool (true|false|1|0|yes|no): {text}`, 2)
end

-- secrets
local function secret_string(name: string, default: string?): string
	local value = await_read(name) or default or missing(name)
	if not table.find(secrets, value) then table.insert(secrets, value) end
	return value
end

local function redact(text: string): string
	for _, secret in secrets do
		text = text:gsub(secret:gsub('%p', '%%%0'), '***')
	end
	return text
end

-- module
return table.freeze {
	await_values = await_values,
	await_is_set = await_is_set,
	string = string_var,
	number = number_var,
	bool = bool_var,
	secret = table.freeze { string = secret_string },
	redact = redact,
}
