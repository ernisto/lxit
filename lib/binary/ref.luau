-- vars
export type ref = {
	id: string,
	owner: string,
	repo: string,
	version: string?,
}

-- functions
local function parse(text: string): ref
	local owner, repo, version = text:match '^([%w_.-]+)/([%w_.-]+)@?(.*)$'
	assert(owner and repo, `invalid bin "{text}", expected owner/repo or owner/repo@version`)

	return table.freeze {
		id = text,
		owner = owner,
		repo = repo,
		version = if version ~= '' then version else nil,
	}
end

-- module
return table.freeze {
	parse = parse,
}
