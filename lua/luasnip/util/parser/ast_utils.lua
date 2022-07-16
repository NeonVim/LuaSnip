local types = require("luasnip.util.parser.neovim_ast").node_type
local Node_mt = getmetatable(
	require("luasnip.util.parser.neovim_parser").parse("$0")
)
local util = require("luasnip.util.util")
local jsregexp_ok, jsregexp = pcall(require, "jsregexp")

local M = {}

---Walks ast pre-order, from left to right, applying predicate fn.
---The walk is aborted as soon as fn matches (eg. returns true).
---The walk does not recurse into Transform or choice, eg. it only covers nodes
---that can be jumped (in)to.
---@param ast table: the tree.
---@param fn function: the predicate.
---@return boolean: whether the predicate matched.
local function predicate_ltr_nodes(ast, fn)
	if fn(ast) then
		return true
	end
	if ast.type == types.PLACEHOLDER or ast.type == types.SNIPPET then
		for _, node in ipairs(ast.children) do
			if predicate_ltr_nodes(node, fn) then
				return true
			end
		end
	end

	return false
end

--- Find type of 0-placeholder/choice/tabstop, if it exists.
--- Ignores transformations.
---@param ast table: ast
---@return number, number: first, the type of the node with position 0, then
--- the child of `ast` containing it.
local function zero_node(ast)
	-- find placeholder/tabstop/choice with position 0, but ignore those that
	-- just apply transformations, this should return the node where the cursor
	-- ends up on exit.
	-- (this node should also exist in this snippet, as long as it was formatted
	-- correctly).
	if ast.tabstop == 0 and not ast.transform then
		return ast
	end
	for indx, child in ipairs(ast.children or {}) do
		local zn, _ = zero_node(child)
		if zn then
			return zn, indx
		end
	end

	-- no 0-node in this ast.
	return nil, nil
end

local function count_tabstop(ast, tabstop_indx)
	local count = 0

	predicate_ltr_nodes(ast, function(node)
		if node.tabstop == tabstop_indx then
			count = count + 1
		end
		-- only stop once all nodes were looked at.
		return false
	end)

	return count
end

local function text_only_placeholder(placeholder)
	local only_text = true
	predicate_ltr_nodes(placeholder, function(node)
		if node.type ~= types.TEXT then
			only_text = false
			-- we found non-text, no need to search more.
			return true
		end
	end)

	return only_text
end

local function max_position(ast)
	local max = -1
	predicate_ltr_nodes(ast, function(node)
		local new_max = node.tabstop or -1
		if new_max > max then
			max = new_max
		end
		-- don't stop early.
		return false
	end)

	return max
end

local function replace_position(ast, p1, p2)
	predicate_ltr_nodes(ast, function(node)
		if node.tabstop == p1 then
			node.tabstop = p2
		end
		-- look at all nodes.
		return false
	end)
end

local is_interactive
local has_interactive_children = function(node, root)
	-- make sure all children are not interactive
	for _, child in ipairs(node.children) do
		if is_interactive(child, root) then
			return false
		end
	end
	return true
end
local type_is_interactive = {
	[types.SNIPPET] = has_interactive_children,
	[types.TEXT] = util.no,
	[types.TABSTOP] = function(node, root)
		local tabstop_is_copy = false
		predicate_ltr_nodes(root, function(pred_node)
			-- stop at this tabstop
			if pred_node == node then
				return true
			end
			-- stop if match found
			if pred_node.tabstop == node.tabstop then
				tabstop_is_copy = true
				return true
			end
			-- otherwise, continue.
			return false
		end)
		-- this tabstop is interactive if it is not a copy.
		return not tabstop_is_copy
	end,
	[types.PLACEHOLDER] = has_interactive_children,
	[types.VARIABLE] = util.no,
	[types.CHOICE] = util.yes,
}
local function is_interactive(node, snippet)
	return type_is_interactive[node.type](node, snippet)
end

function M.fix_zero(ast)
	local zn, ast_child_with_0_indx = zero_node(ast)
	-- if zn exists, is a tabstop, an immediate child of `ast`, and does not
	-- have to be copied, the snippet can be accurately represented by luasnip.
	-- (also if zn just does not exist, ofc).
	--
	-- If the snippet can't be represented as-is, the ast needs to be modified
	-- as described below.
	if
		not zn
		or (
			zn
			and (
				zn.type == types.TABSTOP or
				(zn.type == types.PLACEHOLDER and text_only_placeholder(zn))
			)
			and ast.children[ast_child_with_0_indx] == zn
			and count_tabstop(ast, 0) <= 1
		)
	then
		return
	end

	-- bad, a choice or placeholder is at position 0.
	-- replace all ${0:...} with ${n+1:...} (n highest position)
	-- max_position is at least 0, all's good.
	local max_pos = max_position(ast)
	replace_position(ast, 0, max_pos + 1)

	-- insert $0 as a direct child to snippet.
	table.insert(
		ast.children,
		ast_child_with_0_indx + 1,
		setmetatable({
			type = types.TABSTOP,
			tabstop = 0,
		}, Node_mt)
	)
end

-- tested in vscode:
-- in "${1|b,c|} ${1:aa}" ${1:aa} is the copy,
-- in "${1:aa}, ${1|b,c|}" ${1|b,c} is the copy => with these two the position
-- determines which is the real tabstop => they have the same priority.
-- in "$1 ${1:aa}", $1 is the copy, so it has to have a lower priority.
local type_real_tabstop_prio = {
	[types.TABSTOP] = 1,
	[types.PLACEHOLDER] = 2,
	[types.CHOICE] = 2,
}

---The name of this function is horrible, but I can't come up with something
---more succinct.
---The idea here is to find which of two nodes is "smaller" in a
---"real-tabstop"-ordering relation on all the nodes of a snippet.
---REQUIREMENT!!! The nodes have to be passed in the order they appear in in
---the snippet, eg. prev_node has to appear earlier in the text (or be a parent
---of) current_node.
---@param prev_node table: the ast node earlier in the text.
---@param current_node table: the other ast node.
---@return boolean: true if prev_node is less than (according to the
---"real-tabstop"-ordering described above and in the docstring of
---`add_dependents`), false otherwise.
local function real_tabstop_order_less(prev_node, current_node)
	local prio_prev = type_real_tabstop_prio[prev_node.type]
	local prio_current = type_real_tabstop_prio[current_node.type]
	-- if type-prio is the same, the one that appeared earlier is the real tabstop.
	return prio_prev == prio_current and false or prio_prev < prio_current
end

---This function identifies which tabstops/placeholder/choices are copies, and
---which are "real tabstops"(/choices/placeholders). The real tabstops are
---extended with a list of their dependents.
---
---Rules for which node of any two nodes with the same tabstop-index is the
---real tabstop:
--- - if one is a tabstop and the other a placeholder/choice, the
---   placeholder/choice is the real tabstop.
--- - if they are both tabstop or both placeholder/choice, the one which
---   appears earlier in the snippet is the real tabstop.
---   (in "${1: ${1:lel}}" the outer ${1:...} appears earlier).
---
---@param ast table: the AST.
function M.add_dependents(ast)
	-- all nodes that have a tabstop.
	-- map tabstop-index (number) -> node.
	local tabstops = {}

	-- nodes which copy some tabstop.
	-- map tabstop-index (number) -> node[] (since there could be multiple copies of that one snippet).
	local copies = {}

	predicate_ltr_nodes(ast, function(node)
		if not tabstops[node.tabstop] then
			tabstops[node.tabstop] = node
			-- continue, we want to find all dependencies.
			return false
		end
		if real_tabstop_order_less(tabstops[node.tabstop], node) then
			table.insert(copies, tabstops[node.tabstop])
			tabstops[node.tabstop] = node
		else
			table.insert(copies, node)
		end
		-- continue.
		return false
	end)

	-- associate real tabstop with its copies (by storing the copies in the real tabstop).
	for i, real_tabstop in ipairs(tabstops) do
		real_tabstop.dependents = {}
		for _, copy in ipairs(copies[i] or {}) do
			table.insert(real_tabstop.dependents, copy)
		end
	end
end

local modifiers = setmetatable({
	upcase = string.upper,
	downcase = string.lower,
	capitalize = function(string)
		-- uppercase first character only.
		return string:sub(1, 1):upper() .. string:sub(2, -1)
	end,
}, {
	__index = function()
		-- return string unmodified.
		-- TODO: log an error/warning here.
		return util.id
	end,
})
local function apply_modifier(text, modifier)
	return modifiers[modifier](text)
end

local function apply_transform_format(nodes, captures)
	local transformed = ""
	for _, node in ipairs(nodes) do
		if node.type == types.TEXT then
			transformed = transformed .. node.esc
		else
			local capture = captures[node.capture_index]
			-- capture exists if it ..exists.. and is nonempty.
			if capture and #capture > 0 then
				if node.if_text then
					transformed = transformed .. node.if_text
				elseif node.modifier then
					transformed = transformed
						.. apply_modifier(capture, node.modifier)
				else
					transformed = transformed .. capture
				end
			else
				if node.else_text then
					transformed = transformed .. node.else_text
				end
			end
		end
	end

	return transformed
end

function M.apply_transform(transform)
	if jsregexp_ok then
		local reg_compiled = jsregexp.compile(
			transform.pattern,
			transform.option
		)
		-- can be passed to functionNode!
		return function(lines)
			-- luasnip expects+passes lines as list, but regex needs one string.
			lines = table.concat(lines, "\\n")
			local matches = reg_compiled(lines)

			local transformed = ""
			-- index one past the end of previous match.
			-- This is used to append unmatched characters to `transformed`, so
			-- it's initialized with 1.
			local prev_match_end = 1
			for _, match in ipairs(matches) do
				-- -1: begin_ind is inclusive.
				transformed = transformed
					.. lines:sub(prev_match_end, match.begin_ind - 1)
					.. apply_transform_format(transform.format, match.groups)

				-- end-exclusive
				prev_match_end = match.end_ind
			end
			transformed = transformed .. lines:sub(prev_match_end, #lines)

			return vim.split(transformed, "\n")
		end
	else
		-- without jsregexp, we cannot properly transform whatever is supposed to
		-- be transformed here.
		-- Just return a function that returns the to-be-transformed string
		-- unmodified.
		return util.id
	end
end

---Variables need the text which is in front of them to determine whether they
---have to be indented ("asdf\n\t$TM_SELECTED_TEXT": vscode indents all lines
---of TM_SELECTED_TEXT).
---@param ast table: the AST.
function M.give_vars_previous_text(ast)
	local last_text = {""}
	-- important: predicate_ltr_nodes visits the node in the order they appear,
	-- textually, in the snippet.
	-- This is necessary to actually ensure the variables actually get the text just in front of them.
	predicate_ltr_nodes(ast, function(node)
		if node.children then
			-- continue if this node is not a leaf.
			-- Since predicate_ltr_nodes runs fn first for the placeholder, and
			-- then for its' children, `last_text` would be reset wrongfully
			-- (example: "asdf\n\t${1:$TM_SELECTED_TEXT}". Here the placeholder
			-- is encountered before the variable -> no indentation).
			--
			-- ignoring non-leaf-nodes makes it so that only the nodes which
			-- actually contribute text (placeholders are "invisible" in that
			-- they don't add text themselves, they do it through their
			-- children) are considered.
			return false
		end
		if node.type == types.TEXT then
			last_text = vim.gsplit(node.esc, "\n")
		elseif node.type == types.VARIABLE then
			node.previous_text = last_text
		else
			-- reset last_text when a different node is encountered.
			last_text = {""}
		end
		-- continue..
		return false
	end)
end

M.types = types
M.Node_mt = Node_mt
return M
