local process = require '@std/process'

local args = { table.unpack(process.args, 2) }

-- removes every spelling of the flag (e.g. `-f`, `--force`); true if any was present
local function take(...: string): boolean
	local found = false
	for _, flag in { ... } do
		local index = table.find(args, flag)
		while index do
			table.remove(args, index)
			found = true
			index = table.find(args, flag)
		end
	end
	return found
end

return table.freeze {
	force = take('-f', '--force'),
	dry_run = take '--dry-run',
	deep = take '--deep',
	assume_yes = take('-y', '--yes'),
	args = table.freeze(args),
}
