local fs = require '@std/fs'
local syntax = require '@std/syntax'
local visitor = require '@std/syntax/visitor'

-- vars
local ENV_KINDS = table.freeze { string = true, number = true, bool = true }

-- lute's ast typedefs use `read` props the old type solver can't index, so nodes stay untyped
type ast = any
export type env_var = { name: string, kind: string, optional: boolean }
-- choices: the literal union (directly or through a type alias), if the param is one
export type param = { name: string, choices: { string }?, optional: boolean }
type task_info = { params: { param }, env: { env_var }, refs: { string }, doc: string? }
export type signature = { params: { param }, env: { env_var }, doc: string? }

-- types
local function literal_union(node: ast): { string }?
	if node.tag == 'group' then return literal_union(node.type) end
	if node.tag == 'string' then return { node.token.text } end
	if node.tag ~= 'union' then return nil end

	local names = {}
	for _, pair in node.types do
		if pair.node.tag == 'optional' then continue end

		local choices = literal_union(pair.node)
		if not choices then return nil end
		table.move(choices, 1, #choices, #names + 1, names)
	end
	return names
end

local function is_optional(node: ast): boolean
	if node.tag ~= 'union' then return false end

	for _, pair in node.types do
		if pair.node.tag == 'optional' then return true end
	end
	return false
end

local function read_param(param: ast, aliases: { [string]: { string } }): param
	local annotation = param.annotation
	if not annotation then return table.freeze { name = param.name.text, optional = false } end

	-- `T?` is a two-member union: read choices off `T`
	local optional = is_optional(annotation)
	local base = if optional and #annotation.types == 2 then annotation.types[1].node else annotation

	local alias = if base.tag == 'reference' then aliases[base.name.text] else nil
	return table.freeze {
		name = param.name.text,
		choices = alias or literal_union(base),
		optional = optional,
	}
end

-- bodies
local function env_var(call: ast): env_var?
	local func = call.func
	if func.tag ~= 'indexname' or not ENV_KINDS[func.index.text] then return nil end
	if func.expression.tag ~= 'local' or func.expression.token.text ~= 'env' then return nil end

	local first = call.arguments[1]
	local name = first and first.node.tag == 'string' and first.node.token.text
	if not name then return nil end

	-- a second arg is the default, so the var is optional
	return table.freeze { name = name, kind = func.index.text, optional = #call.arguments >= 2 }
end

local function add_var(vars: { env_var }, var: env_var)
	for _, existing in vars do
		if existing.name == var.name and existing.kind == var.kind and existing.optional == var.optional then return end
	end
	table.insert(vars, var)
end

local function scan_body(func: ast, tasks_by_local: { [ast]: string }): ({ env_var }, { string })
	local env, refs = {}, {}
	local scan = visitor.create()

	function scan.visitExprCall(call)
		local var = env_var(call)
		if var then add_var(env, var) end
		return true
	end

	function scan.visitExprLocal(expr)
		local ref = tasks_by_local[expr['local']]
		if ref and not table.find(refs, ref) then table.insert(refs, ref) end
		return true
	end

	visitor.visitBlock(func.body, scan)
	return env, refs
end

-- graph
local function collect_env(name: string, infos: { [string]: task_info }, seen: { [string]: true }, into: { env_var })
	if seen[name] then return end
	seen[name] = true

	local info = infos[name]
	for _, var in info.env do
		add_var(into, var)
	end
	for _, ref in info.refs do
		collect_env(ref, infos, seen, into)
	end
end

-- the comment block right above a statement (no blank line between), without `--` markers
local function doc_comment(stat: ast): string?
	local lines = {}
	local trivia = stat.localKeyword.leadingTrivia

	for i = #trivia, 1, -1 do
		local item = trivia[i]
		if item.tag == 'whitespace' then
			local _, newlines = item.text:gsub('\n', '')
			if newlines > 1 then break end
			continue
		end

		local text = if item.tag == 'blockcomment'
			then item.text:match '^%-%-%[=*%[(.-)%]=*%]$'
			else item.text:match '^%-%-+%s?(.*)$'
		table.insert(lines, 1, (text or ''):match '^%s*(.-)%s*$')
	end

	return if #lines > 0 then table.concat(lines, ' ') else nil
end

local function await_parse(path: string): { [string]: task_info }
	local statements = (syntax.parse(fs.readFileToString(path)) :: ast).root.statements
	local aliases: { [string]: { string } } = {}
	local functions, tasks_by_local = {}, {}

	for _, stat in statements do
		local union = if stat.tag == 'typealias' then literal_union(stat.type) else nil
		if union then aliases[stat.name.text] = union end

		if stat.tag == 'localfunction' then
			table.insert(functions, stat)
			tasks_by_local[stat.name] = stat.name.name.text
		end
	end

	local infos = {}
	for _, stat in functions do
		local params = {}
		for _, pair in stat.func.parameters do
			table.insert(params, read_param(pair.node, aliases))
		end

		local env, refs = scan_body(stat.func, tasks_by_local)
		infos[stat.name.name.text] = { params = params, env = env, refs = refs, doc = doc_comment(stat) }
	end
	return infos
end

-- signatures
-- per task: params, doc and env vars read through every referenced fn
local function await_read_signatures(path: string): { [string]: signature }
	local infos = await_parse(path)
	local signatures = {}

	for name, info in infos do
		local vars = {}
		collect_env(name, infos, {}, vars)
		table.sort(vars, function(a, b)
			return a.name < b.name
		end)

		signatures[name] = { params = info.params, env = vars, doc = info.doc }
	end
	return signatures
end

-- module
return table.freeze {
	await_read_signatures = await_read_signatures,
}
