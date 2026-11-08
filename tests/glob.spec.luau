local glob = require '../utils/glob'
local test = require '@std/test'

test.suite('lxit glob', function(suite)
	suite:case('star_stays_inside_one_segment', function(t)
		t.that(glob.match('places/*.luau', 'places/a.luau'))
		t.that(not glob.match('places/*.luau', 'places/lobby/a.luau'))
	end)

	suite:case('double_star_spans_any_depth', function(t)
		t.that(glob.match('places/**/*.luau', 'places/a.luau'))
		t.that(glob.match('places/**/*.luau', 'places/lobby/server/a.luau'))
		t.that(not glob.match('places/**/*.luau', 'shared/a.luau'))
	end)

	suite:case('braces_and_question_mark', function(t)
		t.that(glob.match('{client,server}/?.luau', 'server/x.luau'))
		t.that(not glob.match('{client,server}/?.luau', 'shared/x.luau'))
		t.that(not glob.match('{client,server}/?.luau', 'client/xy.luau'))
	end)

	suite:case('literal_dots_and_backslashes', function(t)
		t.that(not glob.match('*.toml', 'axtoml'))
		t.that(glob.match('config/*.toml', 'config\\modes.toml'))
	end)
end)
