local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer.PlayerGui
local PlayerScripts = LocalPlayer.PlayerScripts

local config = {
    decompile_all = true,
    include_related_source = false,
    max_related_source_chars = 120000,
    snippet_before = 6,
    snippet_after = 8,
    max_calls_per_script = 200,
    max_bindings_per_script = 250,
    scan_runtime = true,
    max_gc_objects = 60000,
    max_gc_matches = 2000,
    max_constants_per_function = 400,
    max_upvalues_per_function = 120,
    runtime_table_depth = 2,
    runtime_table_items = 100,
    max_semantic_scripts = 2500,
    max_semantic_functions = 5000,
    max_functions_per_script = 300,
    max_function_excerpt_chars = 7000,
    max_behavior_functions = 18,
    max_call_edges_per_function = 80,
    max_object_sources_per_function = 40,
    max_ui_bindings = 800,
    max_runtime_preview_values = 8,
    max_world_instances = 40000,
    max_object_catalog = 4000,
    max_tag_samples = 24,
    max_name_group_samples = 8,
    max_name_groups = 800,
    max_object_attributes = 20,
}

local raw_getconstants = getconstants or (debug and debug.getconstants)
local raw_getupvalues = getupvalues or (debug and debug.getupvalues)
local raw_getinfo = getinfo or (debug and debug.getinfo)
local raw_debug_info = debug and debug.info

assert(type(clonefunction) == "function", "clonefunction is required")
assert(type(writefile) == "function", "writefile is required")
assert(type(decompile) == "function", "decompile is required")
assert(type(getgc) == "function", "getgc is required")
assert(type(raw_getconstants) == "function", "getconstants/debug.getconstants is required")
assert(type(raw_getupvalues) == "function", "getupvalues/debug.getupvalues is required")
assert(type(raw_getinfo) == "function" or type(raw_debug_info) == "function","getinfo/debug.getinfo/debug.info is required")

local clone = function(fn)
    return clonefunction(fn)
end

local api = {
    writefile = clone(writefile),
    decompile = clone(decompile),
    getgc = clone(getgc),
    getconstants = clone(raw_getconstants),
    getupvalues = clone(raw_getupvalues),
    getinfo = type(raw_getinfo) == "function" and clone(raw_getinfo) or nil,
    debug_info = type(raw_debug_info) == "function" and clone(raw_debug_info) or nil,
}

local dump = {
    version = "1.0",
    mode = "dump",
    info = {
        place_id = game.PlaceId,
        game_id = game.GameId,
        place_name = game.Name,
        job_id = game.JobId,
        generated_at = os.time(),
    },
    capabilities = {
        decompile = type(api.decompile) == "function",
        getgc = type(api.getgc) == "function",
        getconstants = type(api.getconstants) == "function",
        getupvalues = type(api.getupvalues) == "function",
        getinfo = type(api.getinfo) == "function" or type(api.debug_info) == "function",
        clonefunction = true,
    },
    stats = {
        remotes = 0,
        candidate_scripts = 0,
        decompiled = 0,
        decompile_failed = 0,
        pass1_network_scripts = 0,
        precise_scripts = 0,
        direct_bindings = 0,
        wrapper_bindings = 0,
        outbound_calls = 0,
        inbound_listeners = 0,
        resolved_direct_calls = 0,
        resolved_wrapper_calls = 0,
        unresolved_calls = 0,
        runtime_objects = 0,
        runtime_functions = 0,
        runtime_matches = 0,
        runtime_skipped_self = 0,
        alias_bindings = 0,
        name_fallback_calls = 0,
        suffix_fallback_calls = 0,
        semantic_scripts = 0,
        semantic_functions = 0,
        semantic_call_edges = 0,
        ui_action_bindings = 0,
        admin_excluded_scripts = 0,
        admin_excluded_remotes = 0,
        admin_excluded_calls = 0,
        admin_excluded_functions = 0,
        admin_excluded_ui_bindings = 0,
        runtime_function_links = 0,
        behavior_count = 0,
        automation_recipe_count = 0,
        auto_ready_behaviors = 0,
        world_instances = 0,
        object_catalog_entries = 0,
        world_tag_groups = 0,
        world_name_groups = 0,
    },
    remotes = {},
    frameworks = {},
    scripts = {},
    runtime = {},
    unresolved = {},
    coverage = {},
}

local safe_string = function(value)
    value = tostring(value)
    local ok, length = pcall(utf8.len, value)
    if ok and length then return value end
    return (value:gsub("[\128-\255]", function(char)
        return string.format("\\x%02X", string.byte(char))
    end))
end

local safe_number = function(value)
    if value ~= value then return "NaN" end
    if value == math.huge then return "inf" end
    if value == -math.huge then return "-inf" end
    return value
end

local trim = function(value)
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

local admin_markers = {
    "admin","cmdr","tester","moderator","moderation",
    "staffpanel","staff_panel","devpanel","dev_panel",
    "developerconsole","developer_console",
    "ownerpanel","owner_panel",
}

local is_admin_related = function(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil then
            local lower = tostring(value):lower()
            for _, marker in admin_markers do
                if lower:find(marker, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

local get_path = function(instance)
    local ok, result = pcall(function()
        return instance:GetFullName()
    end)
    if ok then
        return safe_string(result)
    end
    return safe_string(instance.Name)
end

local is_remote = function(instance)
    return instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") or instance:IsA("UnreliableRemoteEvent")
end

local remote_by_path = {}
local remote_paths_by_name = {}
local remote_instance_to_path = setmetatable({}, {__mode = "k"})

local register_remote = function(instance)
    if not is_remote(instance) then return end

    local path = get_path(instance)
    local name = safe_string(instance.Name)

    if is_admin_related(path, name) then
        dump.stats.admin_excluded_remotes += 1
        return
    end

    if remote_by_path[path] then return end
    local data = {
        name = name,
        path = path,
        class = safe_string(instance.ClassName),
    }

    remote_by_path[path] = data
    remote_instance_to_path[instance] = path
    remote_paths_by_name[name] = remote_paths_by_name[name] or {}
    table.insert(remote_paths_by_name[name], path)
    table.insert(dump.remotes, data)
end

local scan_remote_root = function(root)
    if not root then
        return
    end
    if is_remote(root) then
        register_remote(root)
    end
    local ok, descendants = pcall(function()
        return root:GetDescendants()
    end)
    if not ok then
        return
    end
    for _, instance in ipairs(descendants) do
        if is_remote(instance) then
            register_remote(instance)
        end
    end
end

scan_remote_root(ReplicatedStorage)
scan_remote_root(ReplicatedFirst)
scan_remote_root(workspace)
scan_remote_root(LocalPlayer)
dump.stats.remotes = #dump.remotes

local split_lines = function(source)
    source = source:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (source .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

local make_snippet = function(lines, line_number)
    local first = math.max(1, line_number - config.snippet_before)
    local last = math.min(#lines, line_number + config.snippet_after)
    local out = {}
    for i = first, last do
        table.insert(out, string.format("%d | %s", i, lines[i]))
    end
    return table.concat(out, "\n")
end

local script_priority = function(instance, path)
    path = path or get_path(instance)
    if path:find(".PlayerScripts.Game.", 1, true) then
        return 100
    end
    if path:find(".PlayerScripts.Reusable.", 1, true) then
        return 95
    end
    if path:find(".PlayerScripts.", 1, true) then
        return 90
    end
    if path:find(".PlayerGui.", 1, true) then
        return 80
    end
    if path:find("ReplicatedFirst", 1, true) then
        return 75
    end
    if path:find("ReplicatedStorage.GameServices", 1, true) then
        return 72
    end
    if path:find("ReplicatedStorage.GameData", 1, true) then
        return 70
    end
    if path:find("ReplicatedStorage.Services", 1, true) then
        return 68
    end
    return 40
end

local candidates = {}
local candidate_seen = setmetatable({}, {__mode = "k"})

local collect_scripts = function(root)
    if not root then
        return
    end
    if root:IsA("LuaSourceContainer") and not candidate_seen[root] then
        candidate_seen[root] = true
        local path = get_path(root)

        if is_admin_related(path, root.Name) then
            dump.stats.admin_excluded_scripts += 1
        else
            table.insert(candidates, {instance = root, path = path, priority = script_priority(root, path)})
        end
    end
    local ok, descendants = pcall(function()
        return root:GetDescendants()
    end)
    if not ok then
        return
    end
    for _, instance in ipairs(descendants) do
        if instance:IsA("LuaSourceContainer") and not candidate_seen[instance] then
            candidate_seen[instance] = true
            local path = get_path(instance)

            if is_admin_related(path, instance.Name) then
                dump.stats.admin_excluded_scripts += 1
            else
                table.insert(candidates, {instance = instance, path = path, priority = script_priority(instance, path)})
            end
        end
    end
end

collect_scripts(PlayerScripts)
collect_scripts(PlayerGui)
collect_scripts(ReplicatedFirst)
collect_scripts(ReplicatedStorage)
collect_scripts(workspace)
collect_scripts(LocalPlayer)

table.sort(candidates, function(a, b)
    if a.priority == b.priority then
        return a.path < b.path
    end
    return a.priority > b.priority
end)

dump.stats.candidate_scripts = #candidates

local network_keywords = {
    "net", "network", "remote", "remotes", "knit", "comm", "bridge", "packet", "signal",
}

local contains_network_keyword = function(text)
    local lower = tostring(text):lower()
    for _, keyword in ipairs(network_keywords) do
        if lower:find(keyword, 1, true) then
            return true
        end
    end
    return false
end

local pass1_interesting = function(source)
    if source:find(":FireServer%s*%(") then
        return true
    end
    if source:find(":InvokeServer%s*%(") then
        return true
    end
    if source:find("%.OnClientEvent") or source:find("%.OnClientInvoke") then
        return true
    end
    if source:find(":RemoteEvent%s*%(") or source:find(":RemoteFunction%s*%(") then
        return true
    end
    if source:find(":GetRemote%s*%(") or source:find(":GetRemoteEvent%s*%(") or source:find(":GetRemoteFunction%s*%(") then
        return true
    end
    if contains_network_keyword(source) then
        if source:find(":Fire%s*%(") or source:find(":Send%s*%(") or source:find(":Call%s*%(") or source:find(":Request%s*%(") then
            return true
        end
    end
    return false
end

local decompiled = {}
local semantic_decompiled = {}

if dump.capabilities.decompile then
    for index, item in ipairs(candidates) do
        local ok, source = pcall(api.decompile, item.instance)
        if ok and type(source) == "string" and #source > 0 then
            dump.stats.decompiled += 1
            local path = item.path

            if dump.stats.semantic_scripts < config.max_semantic_scripts then
                semantic_decompiled[path] = {
                    instance = item.instance,
                    source = source,
                    priority = item.priority,
                }
                dump.stats.semantic_scripts += 1
            end

            if pass1_interesting(source) then
                decompiled[path] = {
                    instance = item.instance,
                    source = source,
                    priority = item.priority,
                }
                dump.stats.pass1_network_scripts += 1
            end
        else
            dump.stats.decompile_failed += 1
        end
        if index % 100 == 0 then
            task.wait()
        end
    end
end

local quoted_first_arg = function(rhs)
    local object, method, name = rhs:match('^([%a_][%w_%.]*)%s*:%s*([%a_][%w_]*)%s*%(%s*"([^"]+)"')
    if object then
        return object, method, name
    end
    object, method, name = rhs:match("^([%a_][%w_%.]*)%s*:%s*([%a_][%w_]*)%s*%(%s*'([^']+)'")
    if object then
        return object, method, name
    end
    object, method, name = rhs:match('^([%a_][%w_%.]*)%s*%.%s*([%a_][%w_]*)%s*%(%s*"([^"]+)"')
    if object then
        return object, method, name
    end
    return rhs:match("^([%a_][%w_%.]*)%s*%.%s*([%a_][%w_]*)%s*%(%s*'([^']+)'")
end

local resolve_path_expr = function(expr, aliases)
    expr = trim(expr):gsub(";%s*$", "")

    while expr:sub(1, 1) == "(" and expr:sub(-1) == ")" do
        expr = trim(expr:sub(2, -2))
    end

    local service = expr:match('^game:GetService%(%s*"([^"]+)"%s*%)$')
        or expr:match("^game:GetService%(%s*'([^']+)'%s*%)$")
    if service then
        return service
    end

    local game_child = expr:match("^game%.([%a_][%w_]*)$")
    if game_child then
        return game_child
    end

    if expr == "workspace" or expr == "game.Workspace" then
        return "Workspace"
    end

    local head = expr:match("^([%a_][%w_]*)")
    if not head then
        return nil
    end

    local base = aliases[head]
    if not base then
        if head == "workspace" then
            base = "Workspace"
        else
            return nil
        end
    end

    local rest = expr:sub(#head + 1)
    while #trim(rest) > 0 do
        local s, e, child = rest:find('^%s*:WaitForChild%(%s*"([^"]+)"[^%)]*%)')
        if not s then
            s, e, child = rest:find("^%s*:WaitForChild%(%s*'([^']+)'[^%)]*%)")
        end
        if not s then
            s, e, child = rest:find('^%s*:FindFirstChild%(%s*"([^"]+)"[^%)]*%)')
        end
        if not s then
            s, e, child = rest:find("^%s*:FindFirstChild%(%s*'([^']+)'[^%)]*%)")
        end
        if s then
            base = base .. "." .. child
            rest = rest:sub(e + 1)
        else
            local bs, be, bracket_child = rest:find('^%s*%[%s*"([^"]+)"%s*%]')
            if not bs then
                bs, be, bracket_child = rest:find("^%s*%[%s*'([^']+)'%s*%]")
            end
            if bs then
                base = base .. "." .. bracket_child
                rest = rest:sub(be + 1)
            else
                local ds, de, dot_child = rest:find("^%s*%.([%a_][%w_]*)")
                if ds then
                    base = base .. "." .. dot_child
                    rest = rest:sub(de + 1)
                else
                    return nil
                end
            end
        end
    end

    return base
end

local wrapper_constructor_methods = {
    RemoteEvent = true,
    RemoteFunction = true,
    GetRemote = true,
    GetRemoteEvent = true,
    GetRemoteFunction = true,
    GetEvent = true,
    GetFunction = true,
    ReferenceBridge = true,
    CreateBridge = true,
    GetBridge = true,
}

local outbound_methods = {
    FireServer = "client_to_server",
    InvokeServer = "client_to_server",
    Fire = "client_to_server",
    Send = "client_to_server",
    Call = "client_to_server",
    Invoke = "client_to_server",
    Request = "client_to_server",
}

local framework_name_from_object = function(object, framework_vars, service_vars)
    local root = object:match("^([%a_][%w_]*)")
    if not root then
        return nil
    end
    if framework_vars[root] then
        return framework_vars[root].name
    end
    if service_vars[root] then
        return service_vars[root].framework
    end
    return nil
end

local capture_parenthesized = function(lines, start_line, open_col)
    local depth = 0
    local quote = nil
    local escape = false
    local out = {}

    for line_number = start_line, #lines do
        local line = lines[line_number]
        local start_col = line_number == start_line and open_col or 1
        local i = start_col
        while i <= #line do
            local c = line:sub(i, i)
            if quote then
                if depth >= 1 then
                    table.insert(out, c)
                end
                if escape then
                    escape = false
                elseif c == "\\" then
                    escape = true
                elseif c == quote then
                    quote = nil
                end
            else
                if c == '"' or c == "'" then
                    quote = c
                    if depth >= 1 then
                        table.insert(out, c)
                    end
                elseif c == "(" then
                    depth += 1
                    if depth > 1 then
                        table.insert(out, c)
                    end
                elseif c == ")" then
                    depth -= 1
                    if depth == 0 then
                        return table.concat(out), line_number
                    end
                    if depth >= 1 then
                        table.insert(out, c)
                    end
                else
                    if depth >= 1 then
                        table.insert(out, c)
                    end
                end
            end
            i += 1
        end
        if depth >= 1 then
            table.insert(out, "\n")
        end
    end

    return table.concat(out), #lines
end

local split_top_level = function(text)
    local result = {}
    local current = {}
    local paren, brace, bracket = 0, 0, 0
    local quote = nil
    local escape = false

    local flush = function()
        local value = trim(table.concat(current))
        if value ~= "" then
            table.insert(result, value)
        end
        current = {}
    end

    for i = 1, #text do
        local c = text:sub(i, i)
        if quote then
            table.insert(current, c)
            if escape then
                escape = false
            elseif c == "\\" then
                escape = true
            elseif c == quote then
                quote = nil
            end
        else
            if c == '"' or c == "'" then
                quote = c
                table.insert(current, c)
            elseif c == "(" then
                paren += 1
                table.insert(current, c)
            elseif c == ")" then
                paren -= 1
                table.insert(current, c)
            elseif c == "{" then
                brace += 1
                table.insert(current, c)
            elseif c == "}" then
                brace -= 1
                table.insert(current, c)
            elseif c == "[" then
                bracket += 1
                table.insert(current, c)
            elseif c == "]" then
                bracket -= 1
                table.insert(current, c)
            elseif c == "," and paren == 0 and brace == 0 and bracket == 0 then
                flush()
            else
                table.insert(current, c)
            end
        end
    end
    flush()
    return result
end

local infer_argument
infer_argument = function(expression)
    expression = trim(expression)
    local data = {expression = safe_string(expression)}

    if expression == "" then
        data.kind = "empty"
        return data
    end

    if expression == "nil" then
        data.kind = "nil"
        return data
    end

    if expression == "true" or expression == "false" then
        data.kind = "boolean"
        data.value = expression == "true"
        return data
    end

    local number = tonumber(expression)
    if number ~= nil then
        data.kind = "number"
        data.value = safe_number(number)
        return data
    end

    local string_value = expression:match('^"(.*)"$') or expression:match("^'(.*)'$")
    if string_value ~= nil then
        data.kind = "string"
        data.value = safe_string(string_value)
        return data
    end

    if expression:sub(1, 1) == "{" and expression:sub(-1) == "}" then
        data.kind = "table"
        data.fields = {}
        data.array = {}
        local body = expression:sub(2, -2)
        for _, item in ipairs(split_top_level(body)) do
            local key, value = item:match("^([%a_][%w_]*)%s*=%s*(.+)$")
            if key then
                data.fields[key] = infer_argument(value)
            else
                local bracket_key, bracket_value = item:match("^%[(.-)%]%s*=%s*(.+)$")
                if bracket_key then
                    table.insert(data.array, {
                        key = infer_argument(bracket_key),
                        value = infer_argument(bracket_value),
                    })
                else
                    table.insert(data.array, infer_argument(item))
                end
            end
        end
        return data
    end

    local attribute = expression:match(':GetAttribute%(%s*"([^"]+)"%s*%)')
        or expression:match(":GetAttribute%(%s*'([^']+)'%s*%)")
    if attribute then
        data.kind = "attribute_expression"
        data.attribute = attribute
        return data
    end

    local property = expression:match("%.([%a_][%w_]*)%s*$")
    if property then
        data.kind = "property_expression"
        data.property = property
        return data
    end

    if expression:match("^[%a_][%w_]*$") then
        data.kind = "variable"
        return data
    end

    data.kind = "expression"
    return data
end

local analyze_arguments = function(raw)
    local args = {}
    for index, expression in ipairs(split_top_level(raw)) do
        local data = infer_argument(expression)
        data.index = index
        table.insert(args, data)
    end
    return args
end

local find_function_context = function(lines, line_number)
    local minimum = math.max(1, line_number - 160)
    for i = line_number, minimum, -1 do
        local line = lines[i]
        local name = line:match("^%s*local%s+function%s+([%a_][%w_]*)%s*%(")
            or line:match("^%s*function%s+([%a_][%w_%.:]*)%s*%(")
        if name then
            return {name = safe_string(name), declaration_line = i, kind = "named"}
        end

        local event = line:match("([%a_][%w_%.]*)%.OnClientEvent%s*:%s*Connect%s*%(%s*function")
            or line:match("([%a_][%w_%.]*)%s*:%s*Connect%s*%(%s*function")
        if event then
            return {name = "callback:" .. safe_string(event), declaration_line = i, kind = "callback"}
        end
    end
    return {name = "<chunk>", kind = "chunk"}
end

local receiver_before_method = function(line, method_start)
    local prefix = line:sub(1, method_start - 1)
    return prefix:match("([%a_][%w_%.]*)%s*$")
end

local fallback_deny_names = {
    RemoteEvent = true,
    RemoteFunction = true,
    UnreliableRemoteEvent = true,
    Remotes = true,
    Remote = true,
    Event = true,
    Function = true,
}

local unique_remote_name = function(name)
    if not name or fallback_deny_names[name] then
        return nil
    end
    local paths = remote_paths_by_name[name]
    if paths and #paths == 1 then
        return paths[1]
    end
    return nil
end

local unique_remote_suffix = function(receiver)
    if not receiver or receiver == "" then
        return nil
    end
    local suffix = "." .. receiver
    local found = nil
    for path in pairs(remote_by_path) do
        if path:sub(-#suffix) == suffix then
            if found and found ~= path then
                return nil
            end
            found = path
        end
    end
    return found
end

local resolve_receiver_path = function(receiver, aliases, direct_bindings)
    if not receiver then
        return nil, nil
    end
    if direct_bindings[receiver] then
        return direct_bindings[receiver], "binding"
    end

    local root, rest = receiver:match("^([%a_][%w_]*)(.*)$")
    if root then
        local base = direct_bindings[root] or aliases[root]
        if base then
            for part in rest:gmatch("%.([%a_][%w_]*)") do
                base = base .. "." .. part
            end
            if remote_by_path[base] then
                return base, "path"
            end
        end
    end

    if receiver:find("%.") then
        local suffix_path = unique_remote_suffix(receiver)
        if suffix_path then
            return suffix_path, "suffix_fallback"
        end
    end

    local leaf = receiver:match("([%a_][%w_]*)$")
    local name_path = unique_remote_name(leaf)
    if name_path then
        return name_path, "name_fallback"
    end

    return nil, nil
end

local strict_framework_keywords = {
    "net", "network", "remote", "knit", "comm", "bridge", "packet", "replicator",
}

local likely_network_framework = function(name, source)
    local text = (tostring(name) .. " " .. tostring(source)):lower()
    for _, keyword in ipairs(strict_framework_keywords) do
        if text:find(keyword, 1, true) then
            return true
        end
    end
    return false
end

local framework_registry = {}
local framework_evidence_seen = {}
local register_framework = function(name, source, evidence)
    name = safe_string(name)
    local entry = framework_registry[name]
    if not entry then
        entry = {name = name, evidence = {}}
        framework_registry[name] = entry
        table.insert(dump.frameworks, entry)
    end
    local item = safe_string((evidence or "network_behavior") .. ": " .. tostring(source))
    local key = name .. "|" .. item
    if not framework_evidence_seen[key] then
        framework_evidence_seen[key] = true
        table.insert(entry.evidence, item)
    end
end

local analyze_script = function(path, item)
    local source = item.source
    local lines = split_lines(source)
    local aliases = {
        workspace = "Workspace",
    }
    local direct_bindings = {}
    local wrapper_bindings = {}
    local framework_vars = {}
    local service_vars = {}
    local bindings_out = {}
    local calls = {}
    local listeners = {}
    local binding_count = 0

    for line_number, line in ipairs(lines) do
        local lhs, rhs = line:match("^%s*local%s+([%a_][%w_]*)%s*=%s*(.-)%s*;?%s*$")
        if not lhs then
            lhs, rhs = line:match("^%s*([%a_][%w_]*)%s*=%s*(.-)%s*;?%s*$")
        end

        if lhs and rhs then
            local resolved = resolve_path_expr(rhs, aliases)
            if resolved then
                if aliases[lhs] ~= resolved then
                    dump.stats.alias_bindings += 1
                end
                aliases[lhs] = resolved
                if remote_by_path[resolved] then
                    direct_bindings[lhs] = resolved
                    binding_count += 1
                    dump.stats.direct_bindings += 1
                    if #bindings_out < config.max_bindings_per_script then
                        table.insert(bindings_out, {
                            variable = lhs,
                            kind = "direct_remote",
                            path = resolved,
                            class = remote_by_path[resolved].class,
                            line = line_number,
                        })
                    end
                end
            elseif direct_bindings[trim(rhs)] then
                direct_bindings[lhs] = direct_bindings[trim(rhs)]
            end

            if rhs:find("^require%s*%(") and likely_network_framework(lhs, rhs) then
                framework_vars[lhs] = {name = lhs, source = rhs}
            end

            local object, method, endpoint = quoted_first_arg(rhs)
            if object and method and endpoint then
                local framework = framework_name_from_object(object, framework_vars, service_vars)
                if framework and (method == "GetService" or method == "Service" or method == "GetController" or method == "Controller") then
                    service_vars[lhs] = {
                        framework = framework,
                        service = endpoint,
                    }
                    if #bindings_out < config.max_bindings_per_script then
                        table.insert(bindings_out, {
                            variable = lhs,
                            kind = "framework_service",
                            framework = safe_string(framework),
                            service = safe_string(endpoint),
                            constructor = safe_string(method),
                            line = line_number,
                        })
                    end
                else
                    local explicit_network_constructor = method == "RemoteEvent"
                        or method == "RemoteFunction"
                        or method == "GetRemote"
                        or method == "GetRemoteEvent"
                        or method == "GetRemoteFunction"
                        or method == "ReferenceBridge"
                        or method == "CreateBridge"
                        or method == "GetBridge"
                    local generic_framework_constructor = framework and (method == "GetEvent"
                        or method == "GetFunction"
                        or method == "Get"
                        or method == "Event"
                        or method == "Function"
                        or method == "Signal"
                        or method == "Bridge")
                    if explicit_network_constructor or generic_framework_constructor then
                    framework = framework or object:match("^([%a_][%w_]*)") or object
                    wrapper_bindings[lhs] = {
                        framework = framework,
                        endpoint = endpoint,
                        constructor = method,
                        source_object = object,
                    }
                    binding_count += 1
                    dump.stats.wrapper_bindings += 1
                    register_framework(framework, object .. ":" .. method, "endpoint_constructor")
                    if #bindings_out < config.max_bindings_per_script then
                        table.insert(bindings_out, {
                            variable = lhs,
                            kind = "wrapper_endpoint",
                            framework = safe_string(framework),
                            endpoint = safe_string(endpoint),
                            constructor = safe_string(method),
                            line = line_number,
                        })
                    end
                    end
                end
            end
        end
    end

    local call_seen = {}

    for line_number, line in ipairs(lines) do
        for method, direction in pairs(outbound_methods) do
            local search_from = 1
            while true do
                local s, e = line:find(":" .. method .. "%s*%(", search_from)
                if not s then
                    break
                end

                local receiver = receiver_before_method(line, s)
                local allow = method == "FireServer" or method == "InvokeServer"
                local wrapper = receiver and wrapper_bindings[receiver] or nil
                local framework = receiver and framework_name_from_object(receiver, framework_vars, service_vars) or nil
                if not allow and not wrapper and not framework then
                    search_from = e + 1
                else
                    local open_col = line:find("%(", s)
                    local raw_args, end_line = capture_parenthesized(lines, line_number, open_col)
                    local direct_path, direct_kind = resolve_receiver_path(receiver, aliases, direct_bindings)
                    local key = table.concat({path, tostring(line_number), tostring(s), method, tostring(receiver)}, "|")
                    if not call_seen[key] then
                        call_seen[key] = true
                        local call = {
                            line = line_number,
                            end_line = end_line,
                            direction = direction,
                            method = method,
                            receiver = receiver and safe_string(receiver) or nil,
                            function_context = find_function_context(lines, line_number),
                            raw_arguments = safe_string(raw_args),
                            arguments = analyze_arguments(raw_args),
                            snippet = safe_string(make_snippet(lines, line_number)),
                        }

                        if direct_path then
                            call.resolution = direct_kind == "name_fallback" and "direct_remote_name_fallback"
                                or direct_kind == "suffix_fallback" and "direct_remote_suffix_fallback"
                                or "direct_remote"
                            call.remote_path = direct_path
                            call.remote_name = remote_by_path[direct_path] and remote_by_path[direct_path].name or nil
                            call.confidence = (direct_kind == "name_fallback" or direct_kind == "suffix_fallback") and "high" or "exact"
                            if direct_kind == "name_fallback" then
                                dump.stats.name_fallback_calls += 1
                            elseif direct_kind == "suffix_fallback" then
                                dump.stats.suffix_fallback_calls += 1
                            end
                            dump.stats.resolved_direct_calls += 1
                        elseif wrapper then
                            local wrapper_path = unique_remote_name(wrapper.endpoint)
                            call.resolution = wrapper_path and "wrapper_remote" or "wrapper_endpoint"
                            call.framework = safe_string(wrapper.framework)
                            call.endpoint = safe_string(wrapper.endpoint)
                            call.constructor = safe_string(wrapper.constructor)
                            call.confidence = wrapper_path and "high" or "framework"
                            if wrapper_path then
                                call.remote_path = wrapper_path
                                call.remote_name = remote_by_path[wrapper_path] and remote_by_path[wrapper_path].name or wrapper.endpoint
                            end
                            register_framework(wrapper.framework, wrapper.source_object .. ":" .. wrapper.constructor, "resolved_call")
                            dump.stats.resolved_wrapper_calls += 1
                        elseif framework then
                            call.resolution = "framework_expression"
                            call.framework = safe_string(framework)
                            call.endpoint = receiver and safe_string(receiver) or nil
                            call.confidence = "framework"
                            register_framework(framework, receiver or "<unknown>", "network_method")
                            dump.stats.resolved_wrapper_calls += 1
                        else
                            call.resolution = "unresolved"
                            dump.stats.unresolved_calls += 1
                            table.insert(dump.unresolved, {
                                script = path,
                                line = line_number,
                                method = method,
                                receiver = receiver and safe_string(receiver) or nil,
                                raw_arguments = safe_string(raw_args),
                            })
                        end

                        table.insert(calls, call)
                        dump.stats.outbound_calls += 1
                        if #calls >= config.max_calls_per_script then
                            break
                        end
                    end
                    search_from = e + 1
                end
            end
            if #calls >= config.max_calls_per_script then
                break
            end
        end

        local receiver, event_name = line:match("([%a_][%w_%.]*)%.(OnClientEvent)%s*:%s*Connect%s*%(")
        if not receiver then
            receiver, event_name = line:match("([%a_][%w_%.]*)%.(OnClientInvoke)%s*=")
        end
        if receiver then
            local direct_path, direct_kind = resolve_receiver_path(receiver, aliases, direct_bindings)
            local wrapper = wrapper_bindings[receiver]
            local listener = {
                line = line_number,
                event = event_name,
                receiver = safe_string(receiver),
                function_context = find_function_context(lines, line_number),
                snippet = safe_string(make_snippet(lines, line_number)),
            }
            if direct_path then
                listener.resolution = direct_kind == "name_fallback" and "direct_remote_name_fallback"
                    or direct_kind == "suffix_fallback" and "direct_remote_suffix_fallback"
                    or "direct_remote"
                listener.remote_path = direct_path
                listener.remote_name = remote_by_path[direct_path] and remote_by_path[direct_path].name or nil
                listener.confidence = (direct_kind == "name_fallback" or direct_kind == "suffix_fallback") and "high" or "exact"
            elseif wrapper then
                local wrapper_path = unique_remote_name(wrapper.endpoint)
                listener.resolution = wrapper_path and "wrapper_remote" or "wrapper_endpoint"
                listener.framework = safe_string(wrapper.framework)
                listener.endpoint = safe_string(wrapper.endpoint)
                listener.remote_path = wrapper_path
                listener.remote_name = wrapper_path and (remote_by_path[wrapper_path] and remote_by_path[wrapper_path].name or wrapper.endpoint) or nil
                register_framework(wrapper.framework, wrapper.source_object .. ":" .. wrapper.constructor, "listener")
            else
                listener.resolution = "unresolved"
            end
            table.insert(listeners, listener)
            dump.stats.inbound_listeners += 1
        end
    end

    if #calls == 0 and #listeners == 0 and binding_count == 0 then
        return nil
    end

    local result = {
        path = path,
        class = safe_string(item.instance.ClassName),
        name = safe_string(item.instance.Name),
        priority = item.priority,
        source_length = #source,
        bindings = bindings_out,
        calls = calls,
        listeners = listeners,
    }

    if config.include_related_source then
        if #source > config.max_related_source_chars then
            result.source = safe_string(source:sub(1, config.max_related_source_chars))
            result.source_truncated = true
        else
            result.source = safe_string(source)
            result.source_truncated = false
        end
    end

    return result
end

local analyzed = 0
for path, item in pairs(decompiled) do
    local result = analyze_script(path, item)
    analyzed += 1
    if result then
        table.insert(dump.scripts, result)
        dump.stats.precise_scripts += 1
    end
    if analyzed % 50 == 0 then
        task.wait()
    end
end

table.sort(dump.scripts, function(a, b)
    if a.priority == b.priority then
        return a.path < b.path
    end
    return a.priority > b.priority
end)

do
    local filtered_scripts = {}

    dump.stats.outbound_calls = 0
    dump.stats.unresolved_calls = 0
    dump.stats.resolved_direct_calls = 0
    dump.stats.resolved_wrapper_calls = 0
    dump.stats.inbound_listeners = 0
    dump.stats.precise_scripts = 0

    for _, script_data in ipairs(dump.scripts) do
        local calls = {}
        local listeners = {}

        for _, call in ipairs(script_data.calls or {}) do
            if is_admin_related(
                script_data.path,
                call.remote_path,
                call.remote_name,
                call.receiver,
                call.endpoint,
                call.raw_arguments,
                call.snippet
            ) then
                dump.stats.admin_excluded_calls += 1
            else
                table.insert(calls, call)
                dump.stats.outbound_calls += 1

                if call.resolution == "unresolved" then
                    dump.stats.unresolved_calls += 1
                elseif call.resolution == "wrapper_remote"
                    or call.resolution == "wrapper_endpoint"
                    or call.resolution == "framework_expression" then
                    dump.stats.resolved_wrapper_calls += 1
                else
                    dump.stats.resolved_direct_calls += 1
                end
            end
        end

        for _, listener in ipairs(script_data.listeners or {}) do
            if is_admin_related(
                script_data.path,
                listener.remote_path,
                listener.remote_name,
                listener.receiver,
                listener.endpoint,
                listener.snippet
            ) then
                dump.stats.admin_excluded_calls += 1
            else
                table.insert(listeners, listener)
                dump.stats.inbound_listeners += 1
            end
        end

        script_data.calls = calls
        script_data.listeners = listeners

        if #calls > 0 or #listeners > 0 or #(script_data.bindings or {}) > 0 then
            table.insert(filtered_scripts, script_data)
            dump.stats.precise_scripts += 1
        end
    end

    dump.scripts = filtered_scripts

    local filtered_unresolved = {}

    for _, item in ipairs(dump.unresolved) do
        if not is_admin_related(
            item.script,
            item.receiver,
            item.remote_path,
            item.remote_name,
            item.raw_arguments
        ) then
            table.insert(filtered_unresolved, item)
        end
    end

    dump.unresolved = filtered_unresolved
    dump.stats.unresolved_calls = #filtered_unresolved
end

local add_unique = function(list, set, value)
    if value ~= nil and not set[value] then
        set[value] = true
        table.insert(list, value)
    end
end

local scan_runtime_value
scan_runtime_value = function(value, remote_refs, remote_set, endpoint_refs, endpoint_set, depth, seen, known_endpoints)
    depth = depth or 0
    seen = seen or {}
    local value_type = typeof(value)

    if value_type == "Instance" then
        local path = remote_instance_to_path[value]
        if path then
            add_unique(remote_refs, remote_set, path)
        end
        return
    end

    if value_type == "string" then
        if remote_paths_by_name[value] then
            for _, path in ipairs(remote_paths_by_name[value]) do
                add_unique(remote_refs, remote_set, path)
            end
        end
        if known_endpoints[value] then
            add_unique(endpoint_refs, endpoint_set, value)
        end
        return
    end

    if value_type ~= "table" or depth >= config.runtime_table_depth or seen[value] then
        return
    end

    seen[value] = true
    local count = 0
    for key, item in pairs(value) do
        count += 1
        if count > config.runtime_table_items then
            break
        end
        scan_runtime_value(key, remote_refs, remote_set, endpoint_refs, endpoint_set, depth + 1, seen, known_endpoints)
        scan_runtime_value(item, remote_refs, remote_set, endpoint_refs, endpoint_set, depth + 1, seen, known_endpoints)
    end
end

local known_endpoints = {}
for _, script_data in ipairs(dump.scripts) do
    for _, binding in ipairs(script_data.bindings or {}) do
        if binding.kind == "wrapper_endpoint" and binding.endpoint then
            known_endpoints[binding.endpoint] = true
        end
    end
end

local get_function_info = function(fn)
    local result = {}
    if api.getinfo then
        local ok, info = pcall(api.getinfo, fn)
        if ok and type(info) == "table" then
            result.name = info.name and safe_string(info.name) or nil
            result.source = info.source and safe_string(info.source) or nil
            result.short_src = info.short_src and safe_string(info.short_src) or nil
            result.currentline = info.currentline
            result.linedefined = info.linedefined
            result.lastlinedefined = info.lastlinedefined
        end
    elseif api.debug_info then
        local ok, source, line, name = pcall(api.debug_info, fn, "sln")
        if ok then
            result.source = source and safe_string(source) or nil
            result.currentline = line
            result.name = name and safe_string(name) or nil
        end
    end
    return result
end

local dumper_function_names = {
    safe_string = true, safe_number = true, trim = true, get_path = true, is_remote = true,
    register_remote = true, scan_remote_root = true, split_lines = true, make_snippet = true,
    script_priority = true, collect_scripts = true, contains_network_keyword = true,
    pass1_interesting = true, quoted_first_arg = true, resolve_path_expr = true,
    framework_name_from_object = true, capture_parenthesized = true, split_top_level = true,
    infer_argument = true, analyze_arguments = true, find_function_context = true,
    receiver_before_method = true, unique_remote_name = true, unique_remote_suffix = true,
    resolve_receiver_path = true, likely_network_framework = true, register_framework = true,
    analyze_script = true, add_unique = true, scan_runtime_value = true, get_function_info = true,
}

local is_dumper_runtime_function = function(info)
    local source = tostring(info and info.source or "")
    local short_src = tostring(info and info.short_src or "")
    local name = tostring(info and info.name or "")
    if dumper_function_names[name] then
        return true
    end
    if source == "@" and short_src == "" then
        return true
    end
    if (source:find("roblox_ai_dumper_v6", 1, true) or short_src:find("roblox_ai_dumper_v6", 1, true) or source:find("roblox_ai_dumper_v5", 1, true) or short_src:find("roblox_ai_dumper_v5", 1, true) or source:find("roblox_ai_dumper_v4", 1, true) or short_src:find("roblox_ai_dumper_v4", 1, true)) then
        return true
    end
    return false
end


local runtime_preview_value = function(value)
    local value_type = typeof(value)

    if value_type == "nil" or value_type == "boolean" or value_type == "number" or value_type == "string" then
        return {type = value_type, value = value_type == "number" and safe_number(value) or safe_string(value)}
    end

    if value_type == "Instance" then
        return {
            type = "Instance",
            class = safe_string(value.ClassName),
            name = safe_string(value.Name),
            path = get_path(value),
        }
    end

    if value_type == "table" then
        local keys = {}
        local count = 0
        for key in pairs(value) do
            count += 1
            if #keys < 10 then
                table.insert(keys, safe_string(key))
            end
            if count >= 50 then
                break
            end
        end
        return {type = "table", key_count_sampled = count, keys = keys}
    end

    if value_type == "function" then
        return {type = "function"}
    end

    return {type = value_type, value = safe_string(value)}
end

if config.scan_runtime and dump.capabilities.getgc then
    local ok, objects = pcall(api.getgc, true)
    if ok and type(objects) == "table" then
        local runtime_seen = {}
        local scanned = 0
        for _, object in pairs(objects) do
            scanned += 1
            if scanned > config.max_gc_objects or #dump.runtime >= config.max_gc_matches then
                break
            end
            dump.stats.runtime_objects += 1

            if type(object) == "function" then
                dump.stats.runtime_functions += 1
                local info = get_function_info(object)
                if is_dumper_runtime_function(info) then
                    dump.stats.runtime_skipped_self += 1
                else
                    local remote_refs, remote_set = {}, {}
                    local endpoint_refs, endpoint_set = {}, {}
                    local runtime_value_seen = {}
                    local upvalue_preview = {}
                    local constant_preview = {}

                    if api.getupvalues then
                        local success, upvalues = pcall(api.getupvalues, object)
                        if success and type(upvalues) == "table" then
                            local count = 0
                            for _, value in pairs(upvalues) do
                                count += 1
                                if count > config.max_upvalues_per_function then
                                    break
                                end
                                scan_runtime_value(value, remote_refs, remote_set, endpoint_refs, endpoint_set, 0, runtime_value_seen, known_endpoints)
                                if #upvalue_preview < config.max_runtime_preview_values then
                                    table.insert(upvalue_preview, runtime_preview_value(value))
                                end
                            end
                        end
                    end

                    if api.getconstants then
                        local success, constants = pcall(api.getconstants, object)
                        if success and type(constants) == "table" then
                            local count = 0
                            for _, constant in pairs(constants) do
                                count += 1
                                if count > config.max_constants_per_function then
                                    break
                                end
                                if #constant_preview < config.max_runtime_preview_values and (type(constant) == "string" or type(constant) == "number" or type(constant) == "boolean") then
                                    table.insert(constant_preview, runtime_preview_value(constant))
                                end
                                if type(constant) == "string" then
                                    if remote_paths_by_name[constant] then
                                        for _, path in ipairs(remote_paths_by_name[constant]) do
                                            add_unique(remote_refs, remote_set, path)
                                        end
                                    end
                                    if known_endpoints[constant] then
                                        add_unique(endpoint_refs, endpoint_set, constant)
                                    end
                                end
                            end
                        end
                    end

                    if #remote_refs > 0 or #endpoint_refs > 0 then
                        local key = table.concat({
                            tostring(info.source),
                            tostring(info.linedefined),
                            tostring(info.currentline),
                            table.concat(remote_refs, ","),
                            table.concat(endpoint_refs, ","),
                        }, "|")
                        if not runtime_seen[key] then
                            runtime_seen[key] = true
                            table.insert(dump.runtime, {
                                info = info,
                                remote_paths = remote_refs,
                                wrapper_endpoints = endpoint_refs,
                                upvalue_preview = upvalue_preview,
                                constant_preview = constant_preview,
                            })
                            dump.stats.runtime_matches += 1
                        end
                    end
                end
            end

            if scanned % 5000 == 0 then
                task.wait()
            end
        end
    end
end

local resolved = dump.stats.resolved_direct_calls + dump.stats.resolved_wrapper_calls
local total = dump.stats.outbound_calls
local rate = total > 0 and (resolved / total * 100) or 0

dump.coverage = {
    outbound_total = total,
    resolved = resolved,
    unresolved = dump.stats.unresolved_calls,
    precise_resolution_percent = math.floor(rate * 100 + 0.5) / 100,
    frameworks_detected = #dump.frameworks,
    name_fallback_calls = dump.stats.name_fallback_calls,
    suffix_fallback_calls = dump.stats.suffix_fallback_calls,
    runtime_skipped_self = dump.stats.runtime_skipped_self,
    note = "Remote resolution is client-side evidence only. V6 keeps the precise resolver and adds universal function, object, UI-action, runtime, state, workflow, and automation-recipe analysis. Server-only validation is not observable from the client.",
}


local humanize_identifier = function(value)
    value = tostring(value or "")
    value = value:gsub("[_%-]+", " ")
    value = value:gsub("(%l)(%u)", "%1 %2")
    value = value:gsub("(%u)(%u%l)", "%1 %2")
    value = value:gsub("%s+", " ")
    return trim(value)
end

local system_noise = {
    handler = true,
    controller = true,
    client = true,
    server = true,
    system = true,
    manager = true,
    module = true,
    service = true,
    scripts = true,
    script = true,
    reusable = true,
    main = true,
    game = true,
    remotes = true,
    remote = true,
    packages = true,
    package = true,
    ui = true,
}

local first_meaningful_word = function(value)
    local words = humanize_identifier(value)
    for word in words:gmatch("[%w]+") do
        local lowered = word:lower()
        if not system_noise[lowered] and #word >= 3 then
            if lowered:sub(-1) == "s" and #lowered > 4 then
                lowered = lowered:sub(1, -2)
            end
            return lowered:sub(1, 1):upper() .. lowered:sub(2)
        end
    end
    return nil
end

local path_segment_after = function(path, needle)
    local start = path:find(needle, 1, true)
    if not start then
        return nil
    end
    local rest = path:sub(start + #needle)
    return rest:match("^([^%.]+)")
end

local script_system_tag = function(path)
    local segment =
        path_segment_after(path, ".PlayerScripts.Game.")
        or path_segment_after(path, ".PlayerGui.Main.")
        or path_segment_after(path, "ReplicatedStorage.GameServices.")
        or path_segment_after(path, "ReplicatedStorage.Services.")
        or path_segment_after(path, "ReplicatedStorage.GameData.")

    if not segment then
        return nil
    end

    return first_meaningful_word(segment)
end

local remote_system_tag = function(name)
    return first_meaningful_word(name)
end

local add_unique_value = function(list, seen, value)
    if value and value ~= "" and not seen[value] then
        seen[value] = true
        table.insert(list, value)
    end
end

local confidence_rank = function(value)
    if value == "exact" then
        return 4
    end
    if value == "high" then
        return 3
    end
    if value == "framework" then
        return 2
    end
    return 1
end

local argument_signature = function(argument)
    if type(argument) ~= "table" then
        return tostring(argument)
    end

    if argument.kind == "table" then
        local keys = {}
        for key in pairs(argument.fields or {}) do
            table.insert(keys, tostring(key))
        end
        table.sort(keys)

        local parts = {}
        for _, key in ipairs(keys) do
            local field = argument.fields[key]
            table.insert(parts, key .. ":" .. tostring(field and field.kind or "value"))
        end

        if argument.array and #argument.array > 0 then
            table.insert(parts, "array:" .. tostring(#argument.array))
        end

        return "table{" .. table.concat(parts, ",") .. "}"
    end

    return tostring(argument.kind or "unknown")
end

local call_signature = function(call)
    local parts = {}
    for _, argument in ipairs(call.arguments or {}) do
        table.insert(parts, argument_signature(argument))
    end
    return tostring(call.method or "call") .. "(" .. table.concat(parts, ",") .. ")"
end

local internal_markers = {
    "analytics",
    "telemetry",
    "performance",
    "logging",
    "fastflags",
    "abtests",
    "cmdr",
    "conch",
    "replicator",
}

local internal_names = {
    ping = true,
    fps = true,
    focusstate = true,
    menustate = true,
    liveresponse = true,
    liverequest = true,
    libmpframe = true,
    libmpdevice = true,
    libmprequired = true,
    libmprequiring = true,
    acceptremote = true,
}

local looks_internal = function(path, name)
    if is_admin_related(path, name) then
        return true
    end

    local text = (tostring(path or "") .. " " .. tostring(name or "")):lower()
    for _, marker in ipairs(internal_markers) do
        if text:find(marker, 1, true) then
            return true
        end
    end

    local lowered_name = tostring(name or ""):lower()
    return internal_names[lowered_name] == true
end

local protocol_map = {}
local protocol_list = {}

local protocol_key_from_call = function(call)
    if call.remote_path then
        return "remote:" .. call.remote_path
    end

    if call.framework and call.endpoint then
        return "framework:" .. tostring(call.framework) .. ":" .. tostring(call.endpoint)
    end

    return nil
end

local ensure_protocol = function(call)
    local key = protocol_key_from_call(call)
    if not key then
        return nil
    end

    local entry = protocol_map[key]
    if entry then
        return entry
    end

    local remote = call.remote_path and remote_by_path[call.remote_path] or nil
    entry = {
        id = key,
        name = call.remote_name or call.endpoint or (remote and remote.name) or call.receiver or "Unknown",
        path = call.remote_path,
        class = remote and remote.class or nil,
        framework = call.framework,
        endpoint = call.endpoint,
        outbound = {
            count = 0,
            methods = {},
            signatures = {},
            examples = {},
        },
        inbound = {
            count = 0,
            events = {},
            examples = {},
        },
        used_by = {},
        system_tags = {},
        confidence = "unknown",
        confidence_counts = {
            exact = 0,
            high = 0,
            framework = 0,
            unknown = 0,
        },
        internal_or_infrastructure = false,
    }

    protocol_map[key] = entry
    table.insert(protocol_list, entry)
    return entry
end

local protocol_meta = {}

local get_protocol_meta = function(entry)
    local meta = protocol_meta[entry.id]
    if not meta then
        meta = {
            method_seen = {},
            signature_seen = {},
            used_by_seen = {},
            system_seen = {},
            inbound_seen = {},
            call_example_seen = {},
            listener_example_seen = {},
            best_confidence_rank = 0,
        }
        protocol_meta[entry.id] = meta
    end
    return meta
end

for _, script_data in ipairs(dump.scripts) do
    local script_tag = script_system_tag(script_data.path)

    for _, call in ipairs(script_data.calls or {}) do
        if call.resolution ~= "unresolved" then
            local entry = ensure_protocol(call)
            if entry then
                local meta = get_protocol_meta(entry)
                entry.outbound.count += 1

                add_unique_value(entry.outbound.methods, meta.method_seen, call.method)

                local signature = call_signature(call)
                if not meta.signature_seen[signature] then
                    meta.signature_seen[signature] = true
                    table.insert(entry.outbound.signatures, {
                        signature = signature,
                        method = call.method,
                        arguments = call.arguments,
                        raw_arguments = call.raw_arguments,
                    })
                end

                if #entry.outbound.examples < 6 then
                    local example_key = table.concat({
                        script_data.path,
                        tostring(call.line),
                        tostring(call.method),
                        tostring(call.raw_arguments),
                    }, "|")
                    if not meta.call_example_seen[example_key] then
                        meta.call_example_seen[example_key] = true
                        table.insert(entry.outbound.examples, {
                            script = script_data.path,
                            function_context = call.function_context,
                            line = call.line,
                            method = call.method,
                            confidence = call.confidence,
                            arguments = call.arguments,
                            raw_arguments = call.raw_arguments,
                            snippet = call.snippet,
                        })
                    end
                end

                add_unique_value(entry.used_by, meta.used_by_seen, script_data.path)
                add_unique_value(entry.system_tags, meta.system_seen, script_tag)
                add_unique_value(entry.system_tags, meta.system_seen, remote_system_tag(entry.name))

                local confidence = call.confidence or "unknown"
                if entry.confidence_counts[confidence] == nil then
                    entry.confidence_counts[confidence] = 0
                end
                entry.confidence_counts[confidence] += 1

                local rank = confidence_rank(confidence)
                if rank > meta.best_confidence_rank then
                    meta.best_confidence_rank = rank
                    entry.confidence = confidence
                end
            end
        end
    end

    for _, listener in ipairs(script_data.listeners or {}) do
        if listener.resolution ~= "unresolved" then
            local synthetic_call = {
                remote_path = listener.remote_path,
                remote_name = listener.remote_name,
                framework = listener.framework,
                endpoint = listener.endpoint,
                receiver = listener.receiver,
            }

            local entry = ensure_protocol(synthetic_call)
            if entry then
                local meta = get_protocol_meta(entry)
                entry.inbound.count += 1
                add_unique_value(entry.inbound.events, meta.inbound_seen, listener.event)

                if #entry.inbound.examples < 4 then
                    local example_key = table.concat({
                        script_data.path,
                        tostring(listener.line),
                        tostring(listener.event),
                    }, "|")
                    if not meta.listener_example_seen[example_key] then
                        meta.listener_example_seen[example_key] = true
                        table.insert(entry.inbound.examples, {
                            script = script_data.path,
                            function_context = listener.function_context,
                            line = listener.line,
                            event = listener.event,
                            confidence = listener.confidence,
                            snippet = listener.snippet,
                        })
                    end
                end

                add_unique_value(entry.used_by, meta.used_by_seen, script_data.path)
                add_unique_value(entry.system_tags, meta.system_seen, script_tag)
                add_unique_value(entry.system_tags, meta.system_seen, remote_system_tag(entry.name))
            end
        end
    end
end

for _, entry in ipairs(protocol_list) do
    entry.internal_or_infrastructure = looks_internal(entry.path, entry.name)
    table.sort(entry.used_by)
    table.sort(entry.system_tags)
    table.sort(entry.outbound.methods)
    table.sort(entry.inbound.events)
end

table.sort(protocol_list, function(a, b)
    if a.internal_or_infrastructure ~= b.internal_or_infrastructure then
        return not a.internal_or_infrastructure
    end
    if a.outbound.count ~= b.outbound.count then
        return a.outbound.count > b.outbound.count
    end
    return tostring(a.name) < tostring(b.name)
end)

local system_map = {}
local systems = {}

local ensure_system = function(name)
    if not name or name == "" then
        return nil
    end

    local entry = system_map[name]
    if entry then
        return entry
    end

    entry = {
        name = name,
        protocols = {},
        scripts = {},
        outbound_calls = 0,
        inbound_listeners = 0,
        exact_or_high_protocols = 0,
        feature_candidates = {},
    }

    entry._protocol_seen = {}
    entry._script_seen = {}
    entry._feature_seen = {}
    system_map[name] = entry
    table.insert(systems, entry)
    return entry
end

for _, protocol in ipairs(protocol_list) do
    local tags = protocol.system_tags
    if #tags == 0 then
        tags = {"Other"}
    end

    for _, tag in ipairs(tags) do
        local system = ensure_system(tag)
        if system then
            if not system._protocol_seen[protocol.id] then
                system._protocol_seen[protocol.id] = true
                table.insert(system.protocols, {
                    id = protocol.id,
                    name = protocol.name,
                    path = protocol.path,
                    framework = protocol.framework,
                    endpoint = protocol.endpoint,
                    confidence = protocol.confidence,
                    internal_or_infrastructure = protocol.internal_or_infrastructure,
                })
                if protocol.confidence == "exact" or protocol.confidence == "high" then
                    system.exact_or_high_protocols += 1
                end
            end

            system.outbound_calls += protocol.outbound.count
            system.inbound_listeners += protocol.inbound.count

            for _, script_path in ipairs(protocol.used_by) do
                if not system._script_seen[script_path] then
                    system._script_seen[script_path] = true
                    table.insert(system.scripts, script_path)
                end
            end
        end
    end
end

local feature_candidates = {}
local feature_seen = {}

local feature_name_for_protocol = function(protocol)
    local label = humanize_identifier(protocol.name)
    if label == "" then
        label = protocol.endpoint or protocol.id
    end
    return label
end

for _, protocol in ipairs(protocol_list) do
    if protocol.outbound.count > 0 then
        local feature_key = protocol.id
        if not feature_seen[feature_key] then
            feature_seen[feature_key] = true

            local preferred_system = protocol.system_tags[1] or "Other"
            local candidate = {
                name = feature_name_for_protocol(protocol),
                system = preferred_system,
                protocol_id = protocol.id,
                remote_name = protocol.name,
                remote_path = protocol.path,
                framework = protocol.framework,
                endpoint = protocol.endpoint,
                confidence = protocol.confidence,
                outbound_count = protocol.outbound.count,
                recommended_for_ui = not protocol.internal_or_infrastructure,
                requires_ai_review = true,
                evidence = {},
            }

            for i = 1, math.min(3, #protocol.outbound.examples) do
                local example = protocol.outbound.examples[i]
                table.insert(candidate.evidence, {
                    script = example.script,
                    function_context = example.function_context,
                    method = example.method,
                    arguments = example.arguments,
                    line = example.line,
                })
            end

            table.insert(feature_candidates, candidate)

            local system = ensure_system(preferred_system)
            if system and not system._feature_seen[feature_key] then
                system._feature_seen[feature_key] = true
                table.insert(system.feature_candidates, {
                    name = candidate.name,
                    protocol_id = candidate.protocol_id,
                    confidence = candidate.confidence,
                    recommended_for_ui = candidate.recommended_for_ui,
                })
            end
        end
    end
end

table.sort(feature_candidates, function(a, b)
    if a.recommended_for_ui ~= b.recommended_for_ui then
        return a.recommended_for_ui
    end
    local ar = confidence_rank(a.confidence)
    local br = confidence_rank(b.confidence)
    if ar ~= br then
        return ar > br
    end
    if a.system ~= b.system then
        return a.system < b.system
    end
    return a.name < b.name
end)

for _, system in ipairs(systems) do
    system._protocol_seen = nil
    system._script_seen = nil
    system._feature_seen = nil

    table.sort(system.scripts)
    table.sort(system.protocols, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    table.sort(system.feature_candidates, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
end

table.sort(systems, function(a, b)
    if a.outbound_calls ~= b.outbound_calls then
        return a.outbound_calls > b.outbound_calls
    end
    return a.name < b.name
end)

local detected_systems = {}
for i = 1, math.min(30, #systems) do
    table.insert(detected_systems, {
        name = systems[i].name,
        outbound_calls = systems[i].outbound_calls,
        inbound_listeners = systems[i].inbound_listeners,
        protocol_count = #systems[i].protocols,
        script_count = #systems[i].scripts,
    })
end

local recommended_feature_count = 0
local internal_feature_count = 0
for _, candidate in ipairs(feature_candidates) do
    if candidate.recommended_for_ui then
        recommended_feature_count += 1
    else
        internal_feature_count += 1
    end
end

dump.stats.knowledge_protocols = #protocol_list
dump.stats.knowledge_systems = #systems
dump.stats.feature_candidates = #feature_candidates
dump.stats.recommended_feature_candidates = recommended_feature_count
dump.stats.internal_feature_candidates = internal_feature_count



local world_catalog = {}
local world_tag_groups = {}
local world_name_groups = {}
local world_class_counts = {}

local world_attribute_value = function(value)
    local value_type = typeof(value)
    if value_type == "boolean" or value_type == "string" then
        return value
    end
    if value_type == "number" then
        return safe_number(value)
    end
    return safe_string(value)
end

local add_world_group_sample = function(group, path, max_samples)
    group.count += 1
    if #group.samples < max_samples then
        table.insert(group.samples, path)
    end
end

local ok_world, world_descendants = pcall(function()
    return workspace:GetDescendants()
end)

if ok_world and type(world_descendants) == "table" then
    local scanned = 0

    for _, instance in ipairs(world_descendants) do
        scanned += 1
        if scanned > config.max_world_instances then
            break
        end

        dump.stats.world_instances += 1
        local class_name = safe_string(instance.ClassName)
        world_class_counts[class_name] = (world_class_counts[class_name] or 0) + 1

        local path = get_path(instance)
        local name = safe_string(instance.Name)
        local name_group = world_name_groups[name]
        if not name_group and dump.stats.world_name_groups < config.max_name_groups then
            name_group = {name = name, count = 0, classes = {}, samples = {}}
            world_name_groups[name] = name_group
            dump.stats.world_name_groups += 1
        end
        if name_group then
            add_world_group_sample(name_group, path, config.max_name_group_samples)
            name_group.classes[class_name] = (name_group.classes[class_name] or 0) + 1
        end

        local tags = {}
        local tag_ok, tag_values = pcall(CollectionService.GetTags, CollectionService, instance)
        if tag_ok and type(tag_values) == "table" then
            for _, tag in ipairs(tag_values) do
                tag = safe_string(tag)
                table.insert(tags, tag)
                local group = world_tag_groups[tag]
                if not group then
                    group = {tag = tag, count = 0, classes = {}, samples = {}}
                    world_tag_groups[tag] = group
                    dump.stats.world_tag_groups += 1
                end
                add_world_group_sample(group, path, config.max_tag_samples)
                group.classes[class_name] = (group.classes[class_name] or 0) + 1
            end
        end

        local attributes = {}
        local attribute_count = 0
        local attr_ok, attr_values = pcall(instance.GetAttributes, instance)
        if attr_ok and type(attr_values) == "table" then
            for key, value in pairs(attr_values) do
                attribute_count += 1
                if attribute_count <= config.max_object_attributes then
                    attributes[safe_string(key)] = world_attribute_value(value)
                end
            end
        end

        local interesting_class = instance:IsA("Model")
            or instance:IsA("Tool")
            or instance:IsA("ProximityPrompt")
            or instance:IsA("ClickDetector")
            or instance:IsA("Humanoid")
            or instance:IsA("Seat")
            or instance:IsA("VehicleSeat")

        if #world_catalog < config.max_object_catalog and (interesting_class or #tags > 0 or attribute_count > 0) then
            local entry = {
                name = name,
                class = class_name,
                path = path,
                parent = instance.Parent and get_path(instance.Parent) or nil,
                tags = tags,
                attributes = attributes,
            }

            if instance:IsA("BasePart") then
                entry.position = safe_string(instance.Position)
            elseif instance:IsA("Model") then
                local pivot_ok, pivot = pcall(instance.GetPivot, instance)
                if pivot_ok then
                    entry.position = safe_string(pivot.Position)
                end
            end

            table.insert(world_catalog, entry)
            dump.stats.object_catalog_entries += 1
        end

        if scanned % 4000 == 0 then
            task.wait()
        end
    end
end

local world_tag_list = {}
for _, group in pairs(world_tag_groups) do
    table.insert(world_tag_list, group)
end

table.sort(world_tag_list, function(a, b)
    if a.count ~= b.count then
        return a.count > b.count
    end
    return a.tag < b.tag
end)

local world_name_list = {}
for _, group in pairs(world_name_groups) do
    if group.count >= 2 then
        table.insert(world_name_list, group)
    end
end

table.sort(world_name_list, function(a, b)
    if a.count ~= b.count then
        return a.count > b.count
    end
    return a.name < b.name
end)

local semantic_function_list = {}
local semantic_functions_by_script = {}
local semantic_function_lookup = {}
local semantic_ui_bindings = {}
local semantic_behaviors = {}
local semantic_recipes = {}

local strip_lua_line = function(line)
    local out = {}
    local quote = nil
    local escape = false
    local i = 1

    while i <= #line do
        local c = line:sub(i, i)
        local n = line:sub(i + 1, i + 1)

        if quote then
            if escape then
                escape = false
            elseif c == "\\" then
                escape = true
            elseif c == quote then
                quote = nil
            end
            table.insert(out, " ")
        else
            if c == "\"" or c == "'" then
                quote = c
                table.insert(out, " ")
            elseif c == "-" and n == "-" then
                break
            else
                table.insert(out, c)
            end
        end

        i += 1
    end

    return table.concat(out)
end

local function_declaration = function(line)
    local name, args = line:match("^%s*local%s+function%s+([%a_][%w_%.:]*)%s*%((.-)%)")
    if name then
        return name, args, "local_function"
    end

    name, args = line:match("^%s*function%s+([%a_][%w_%.:]*)%s*%((.-)%)")
    if name then
        return name, args, "function"
    end

    name, args = line:match("^%s*local%s+([%a_][%w_]*)%s*=%s*function%s*%((.-)%)")
    if name then
        return name, args, "local_assignment"
    end

    name, args = line:match("^%s*([%a_][%w_%.:]*)%s*=%s*function%s*%((.-)%)")
    if name then
        return name, args, "assignment"
    end

    return nil
end

local block_delta = function(line)
    line = strip_lua_line(line)
    local delta = 0
    local previous = nil

    for token in line:gmatch("[%a_][%w_]*") do
        if token == "function" or token == "for" or token == "while" or token == "repeat" then
            delta += 1
        elseif token == "if" and previous ~= "elseif" then
            delta += 1
        elseif token == "end" or token == "until" then
            delta -= 1
        end
        previous = token
    end

    return delta
end

local find_function_end = function(lines, start_line)
    local depth = 0

    for line_number = start_line, #lines do
        depth += block_delta(lines[line_number])
        if depth <= 0 and line_number > start_line then
            return line_number
        end
    end

    return math.min(#lines, start_line + 300)
end

local semantic_noise_calls = {
    ["if"] = true,
    ["for"] = true,
    ["while"] = true,
    ["function"] = true,
    ["return"] = true,
    ["typeof"] = true,
    ["type"] = true,
    ["tostring"] = true,
    ["tonumber"] = true,
    ["pairs"] = true,
    ["ipairs"] = true,
    ["next"] = true,
    ["pcall"] = true,
    ["xpcall"] = true,
    ["assert"] = true,
    ["select"] = true,
}

local action_keywords = {
    claim = {"claim", "reward", "redeem"},
    collect = {"collect", "pickup", "gather", "grab"},
    purchase = {"buy", "purchase", "shop"},
    sell = {"sell"},
    equip = {"equip", "unequip", "mount"},
    fishing = {"fish", "cast", "reel", "hook", "steer", "rod", "catch"},
    combat = {"attack", "combat", "hit", "damage", "shoot", "swing"},
    movement = {"teleport", "travel", "move", "warp", "fly", "dash"},
    upgrade = {"upgrade", "levelup", "level_up"},
    placement = {"place", "build", "spawn"},
    hatch = {"hatch", "egg", "open"},
    merge = {"merge", "fuse", "fusion"},
    quest = {"quest", "mission", "task"},
    interaction = {"prompt", "interact", "activate", "touch"},
    automation = {"auto", "farm", "loop", "repeat"},
}

local entrypoint_names = {
    start = true,
    init = true,
    toggle = true,
    run = true,
    begin = true,
    activate = true,
    enable = true,
    execute = true,
    play = true,
    bind = true,
    setup = true,
}

local leaf_identifier = function(value)
    return tostring(value or ""):match("([%a_][%w_]*)$") or tostring(value or "")
end

local classify_action = function(name)
    local lower = tostring(name or ""):lower():gsub("[^%w_]", "")

    for category, keywords in pairs(action_keywords) do
        for _, keyword in ipairs(keywords) do
            if lower:find(keyword, 1, true) then
                return category
            end
        end
    end

    return nil
end

local semantic_system_tag = function(path)
    local segment = path:match("%.Controllers%.([^%.]+)")
        or path:match("%.Interfaces%.([^%.]+)")
        or path:match("%.Modules%.([^%.]+)")
        or path:match("%.GameServices%.([^%.]+)")
        or path:match("%.Services%.([^%.]+)")
        or path:match("%.GameData%.([^%.]+)")

    if segment then
        return first_meaningful_word(segment) or humanize_identifier(segment)
    end

    local leaf = path:match("([^%.]+)$")
    return first_meaningful_word(leaf) or humanize_identifier(leaf)
end

local line_range_text = function(lines, first, last, max_chars)
    local out = {}
    local size = 0

    for i = first, last do
        local line = lines[i]
        local next_size = size + #line + 1
        if next_size > max_chars then
            table.insert(out, "...")
            break
        end
        table.insert(out, line)
        size = next_size
    end

    return safe_string(table.concat(out, "\n"))
end

local collect_pattern_values = function(body, pattern, max_items)
    local values = {}
    local seen = {}

    for value in body:gmatch(pattern) do
        value = trim(value)
        if value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(values, safe_string(value))
            if #values >= max_items then
                break
            end
        end
    end

    return values
end

local merge_unique_values = function(target, seen, source, max_items)
    for _, value in ipairs(source or {}) do
        if value and not seen[value] then
            seen[value] = true
            table.insert(target, value)
            if max_items and #target >= max_items then
                return
            end
        end
    end
end

local analyze_semantic_function = function(path, lines, start_line, end_line, name, args, declaration_kind)
    local body = line_range_text(lines, start_line, end_line, config.max_function_excerpt_chars)
    local lower_name = tostring(name):lower()
    local leaf = leaf_identifier(name)
    local parameters = {}

    for _, parameter in ipairs(split_top_level(args or "")) do
        parameter = trim(parameter)
        if parameter ~= "" then
            table.insert(parameters, safe_string(parameter))
        end
    end

    local calls = {}
    local call_seen = {}

    for called in body:gmatch("([%a_][%w_%.:]*)%s*%(") do
        local called_leaf = leaf_identifier(called)
        if not semantic_noise_calls[called_leaf] and not call_seen[called] then
            call_seen[called] = true
            table.insert(calls, safe_string(called))
            if #calls >= config.max_call_edges_per_function then
                break
            end
        end
    end

    local object_sources = {}
    local object_seen = {}

    merge_unique_values(
        object_sources,
        object_seen,
        collect_pattern_values(body, 'CollectionService%s*:%s*GetTagged%s*%(%s*"([^"]+)"', config.max_object_sources_per_function),
        config.max_object_sources_per_function
    )
    merge_unique_values(
        object_sources,
        object_seen,
        collect_pattern_values(body, "CollectionService%s*:%s*GetTagged%s*%(%s*'([^']+)'", config.max_object_sources_per_function),
        config.max_object_sources_per_function
    )

    for expression in body:gmatch("(workspace[%w_%.%[%]\"']+)") do
        if not object_seen[expression] then
            object_seen[expression] = true
            table.insert(object_sources, safe_string(expression))
            if #object_sources >= config.max_object_sources_per_function then
                break
            end
        end
    end

    local child_names = {}
    local child_seen = {}
    merge_unique_values(child_names, child_seen, collect_pattern_values(body, ':WaitForChild%s*%(%s*"([^"]+)"', 20), 30)
    merge_unique_values(child_names, child_seen, collect_pattern_values(body, ":WaitForChild%s*%(%s*'([^']+)'", 20), 30)
    merge_unique_values(child_names, child_seen, collect_pattern_values(body, ':FindFirstChild%s*%(%s*"([^"]+)"', 20), 30)
    merge_unique_values(child_names, child_seen, collect_pattern_values(body, ":FindFirstChild%s*%(%s*'([^']+)'", 20), 30)
    merge_unique_values(object_sources, object_seen, child_names, config.max_object_sources_per_function)

    local attributes = {}
    local attr_seen = {}
    merge_unique_values(attributes, attr_seen, collect_pattern_values(body, ':GetAttribute%s*%(%s*"([^"]+)"', 30), 30)
    merge_unique_values(attributes, attr_seen, collect_pattern_values(body, ":GetAttribute%s*%(%s*'([^']+)'", 30), 30)
    merge_unique_values(attributes, attr_seen, collect_pattern_values(body, ':SetAttribute%s*%(%s*"([^"]+)"', 30), 30)
    merge_unique_values(attributes, attr_seen, collect_pattern_values(body, ":SetAttribute%s*%(%s*'([^']+)'", 30), 30)

    local waits = {}
    local wait_seen = {}
    merge_unique_values(waits, wait_seen, collect_pattern_values(body, "task%.wait%s*%((.-)%)", 12), 12)
    merge_unique_values(waits, wait_seen, collect_pattern_values(body, "[^%w_]wait%s*%((.-)%)", 12), 12)
    if body:find("Heartbeat:Wait", 1, true) then
        add_unique_value(waits, wait_seen, "RunService.Heartbeat")
    end
    if body:find("RenderStepped:Wait", 1, true) then
        add_unique_value(waits, wait_seen, "RunService.RenderStepped")
    end

    local states = {}
    local state_seen = {}
    merge_unique_values(states, state_seen, collect_pattern_values(body, '==%s*"([^"]+)"', 20), 20)
    merge_unique_values(states, state_seen, collect_pattern_values(body, '~=%s*"([^"]+)"', 20), 20)
    merge_unique_values(states, state_seen, collect_pattern_values(body, "==%s*'([^']+)'", 20), 20)
    merge_unique_values(states, state_seen, collect_pattern_values(body, "~=%s*'([^']+)'", 20), 20)

    local state_assignments = {}
    local state_assignment_seen = {}
    for variable, value in body:gmatch('([%a_][%w_%.]*)%s*=%s*"([^"]+)"') do
        local key = variable .. "=" .. value
        if not state_assignment_seen[key] then
            state_assignment_seen[key] = true
            table.insert(state_assignments, {variable = safe_string(variable), value = safe_string(value)})
            add_unique_value(states, state_seen, safe_string(value))
            if #state_assignments >= 24 then
                break
            end
        end
    end
    for variable, value in body:gmatch("([%a_][%w_%.]*)%s*=%s*'([^']+)'") do
        local key = variable .. "=" .. value
        if not state_assignment_seen[key] then
            state_assignment_seen[key] = true
            table.insert(state_assignments, {variable = safe_string(variable), value = safe_string(value)})
            add_unique_value(states, state_seen, safe_string(value))
            if #state_assignments >= 24 then
                break
            end
        end
    end

    local exported = name:find("%.") ~= nil or name:find(":", 1, true) ~= nil or declaration_kind == "assignment"
    local action = classify_action(name)
    local entrypoint = entrypoint_names[leaf:lower()] == true or lower_name:find("toggle", 1, true) ~= nil or lower_name:find("auto", 1, true) ~= nil

    return {
        id = path .. "::" .. name .. "@" .. tostring(start_line),
        script = path,
        name = safe_string(name),
        leaf_name = safe_string(leaf),
        declaration_kind = declaration_kind,
        start_line = start_line,
        end_line = end_line,
        parameters = parameters,
        exported = exported,
        action = action,
        entrypoint = entrypoint,
        calls = calls,
        call_edges = {},
        remote_calls = {},
        inbound_signals = {},
        object_sources = object_sources,
        attributes = attributes,
        waits = waits,
        states = states,
        state_assignments = state_assignments,
        runtime_refs = {},
        source_excerpt = body,
    }
end

local find_semantic_function = function(path, line_number, function_name)
    local functions = semantic_functions_by_script[path]
    if not functions then
        return nil
    end

    if function_name and function_name ~= "<chunk>" then
        local wanted_leaf = leaf_identifier(function_name)
        for _, fn in ipairs(functions) do
            if fn.name == function_name or fn.leaf_name == wanted_leaf then
                if not line_number or (line_number >= fn.start_line and line_number <= fn.end_line) then
                    return fn
                end
            end
        end
    end

    if line_number then
        local best = nil
        for _, fn in ipairs(functions) do
            if line_number >= fn.start_line and line_number <= fn.end_line then
                if not best or fn.start_line > best.start_line then
                    best = fn
                end
            end
        end
        return best
    end

    return nil
end

local semantic_script_count = 0
for path, item in pairs(semantic_decompiled) do
    if #semantic_function_list >= config.max_semantic_functions then
        break
    end

    semantic_script_count += 1
    local lines = split_lines(item.source)
    local functions = {}
    local line_number = 1

    while line_number <= #lines and #functions < config.max_functions_per_script and #semantic_function_list < config.max_semantic_functions do
        local name, args, declaration_kind = function_declaration(lines[line_number])

        if name then
            local end_line = find_function_end(lines, line_number)
            local fn = analyze_semantic_function(path, lines, line_number, end_line, name, args, declaration_kind)

            if is_admin_related(path, name, fn.source_excerpt) then
                dump.stats.admin_excluded_functions += 1
            else
                table.insert(functions, fn)
                table.insert(semantic_function_list, fn)
                semantic_function_lookup[fn.id] = fn
            end

            line_number += 1
        else
            line_number += 1
        end
    end

    if #functions > 0 then
        semantic_functions_by_script[path] = functions
    end

    if semantic_script_count % 50 == 0 then
        task.wait()
    end
end

dump.stats.semantic_functions = #semantic_function_list

for path, functions in pairs(semantic_functions_by_script) do
    local by_name = {}
    local by_leaf = {}

    for _, fn in ipairs(functions) do
        by_name[fn.name] = fn
        by_leaf[fn.leaf_name] = by_leaf[fn.leaf_name] or fn
    end

    for _, fn in ipairs(functions) do
        local edge_seen = {}

        for _, called in ipairs(fn.calls) do
            local target = by_name[called] or by_leaf[leaf_identifier(called)]
            if target and target.id ~= fn.id and not edge_seen[target.id] then
                edge_seen[target.id] = true
                table.insert(fn.call_edges, target.id)
                dump.stats.semantic_call_edges += 1
            end
        end
    end
end


local global_export_by_leaf = {}
local global_export_ambiguous = {}
for _, fn in ipairs(semantic_function_list) do
    if fn.exported then
        local leaf = fn.leaf_name
        if global_export_by_leaf[leaf] and global_export_by_leaf[leaf] ~= fn.id then
            global_export_ambiguous[leaf] = true
        else
            global_export_by_leaf[leaf] = fn.id
        end
    end
end

for _, fn in ipairs(semantic_function_list) do
    local edge_seen = {}
    for _, edge in ipairs(fn.call_edges) do
        edge_seen[edge] = true
    end

    for _, called in ipairs(fn.calls) do
        local leaf = leaf_identifier(called)
        local target_id = not global_export_ambiguous[leaf] and global_export_by_leaf[leaf] or nil
        if target_id and target_id ~= fn.id and not edge_seen[target_id] then
            edge_seen[target_id] = true
            table.insert(fn.call_edges, target_id)
            dump.stats.semantic_call_edges += 1
        end
    end
end

local infer_argument_provenance = function(lines, call, fn)
    local provenance = {}

    if not fn or not call.arguments then
        return provenance
    end

    for _, argument in ipairs(call.arguments) do
        if argument.kind == "variable" then
            local variable = argument.expression
            local minimum = math.max(fn.start_line, call.line - 100)

            for line_number = call.line - 1, minimum, -1 do
                local line = lines[line_number]
                local lhs, rhs = line:match("^%s*local%s+([%a_][%w_]*)%s*=%s*(.-)%s*;?%s*$")
                if not lhs then
                    lhs, rhs = line:match("^%s*([%a_][%w_]*)%s*=%s*(.-)%s*;?%s*$")
                end

                if lhs == variable and rhs and trim(rhs) ~= "" then
                    table.insert(provenance, {
                        argument_index = argument.index,
                        variable = safe_string(variable),
                        source_expression = safe_string(trim(rhs)),
                        source_line = line_number,
                    })
                    break
                end
            end
        elseif argument.kind == "attribute_expression" then
            table.insert(provenance, {
                argument_index = argument.index,
                source = "attribute",
                attribute = argument.attribute,
                expression = argument.expression,
            })
        elseif argument.kind == "property_expression" then
            table.insert(provenance, {
                argument_index = argument.index,
                source = "property",
                property = argument.property,
                expression = argument.expression,
            })
        end
    end

    return provenance
end

for _, script_data in ipairs(dump.scripts) do
    local semantic_item = semantic_decompiled[script_data.path]
    local lines = semantic_item and split_lines(semantic_item.source) or nil

    for _, call in ipairs(script_data.calls or {}) do
        local context_name = call.function_context and call.function_context.name or nil
        local fn = find_semantic_function(script_data.path, call.line, context_name)

        if fn then
            table.insert(fn.remote_calls, {
                line = call.line,
                method = call.method,
                remote_path = call.remote_path,
                remote_name = call.remote_name,
                framework = call.framework,
                endpoint = call.endpoint,
                confidence = call.confidence,
                resolution = call.resolution,
                arguments = call.arguments,
                raw_arguments = call.raw_arguments,
            })

            if lines then
                call.argument_provenance = infer_argument_provenance(lines, call, fn)
                fn.remote_calls[#fn.remote_calls].argument_provenance = call.argument_provenance
            end
        end
    end

    for _, listener in ipairs(script_data.listeners or {}) do
        local context_name = listener.function_context and listener.function_context.name or nil
        local fn = find_semantic_function(script_data.path, listener.line, context_name)

        if fn then
            table.insert(fn.inbound_signals, {
                line = listener.line,
                event = listener.event,
                remote_path = listener.remote_path,
                remote_name = listener.remote_name,
                confidence = listener.confidence,
                resolution = listener.resolution,
            })
        end
    end
end

for _, runtime_entry in ipairs(dump.runtime) do
    local info = runtime_entry.info or {}
    local source = tostring(info.source or info.short_src or "")
    source = source:gsub("^=", "")
    local line_number = tonumber(info.currentline) or tonumber(info.linedefined)
    local fn = find_semantic_function(source, line_number, info.name)

    if fn then
        table.insert(fn.runtime_refs, {
            name = info.name,
            currentline = info.currentline,
            linedefined = info.linedefined,
            lastlinedefined = info.lastlinedefined,
            remote_paths = runtime_entry.remote_paths,
            wrapper_endpoints = runtime_entry.wrapper_endpoints,
        })
        dump.stats.runtime_function_links += 1
    end
end

local ui_event_patterns = {
    {event = "Activated", pattern = "([%a_][%w_%.%[%]\"']*)%.Activated%s*:%s*Connect%s*%("},
    {event = "MouseButton1Click", pattern = "([%a_][%w_%.%[%]\"']*)%.MouseButton1Click%s*:%s*Connect%s*%("},
    {event = "Triggered", pattern = "([%a_][%w_%.%[%]\"']*)%.Triggered%s*:%s*Connect%s*%("},
    {event = "InputBegan", pattern = "([%a_][%w_%.%[%]\"']*)%.InputBegan%s*:%s*Connect%s*%("},
    {event = "TouchTap", pattern = "([%a_][%w_%.%[%]\"']*)%.TouchTap%s*:%s*Connect%s*%("},
}

for path, item in pairs(semantic_decompiled) do
    if #semantic_ui_bindings >= config.max_ui_bindings then
        break
    end

    local lines = split_lines(item.source)

    for line_number, line in ipairs(lines) do
        for _, spec in ipairs(ui_event_patterns) do
            local control = line:match(spec.pattern)

            if control then
                local fn = find_semantic_function(path, line_number, nil)
                local nearby = {}
                local nearby_seen = {}
                local last = math.min(#lines, line_number + 14)
                local snippet_parts = {}

                for i = line_number, last do
                    table.insert(snippet_parts, lines[i])
                    for called in lines[i]:gmatch("([%a_][%w_%.:]*)%s*%(") do
                        local leaf = leaf_identifier(called)
                        if not semantic_noise_calls[leaf] and not nearby_seen[called] then
                            nearby_seen[called] = true
                            table.insert(nearby, safe_string(called))
                            if #nearby >= 20 then
                                break
                            end
                        end
                    end
                end

                local ui_snippet = safe_string(table.concat(snippet_parts, "\n"))

                if is_admin_related(path, control, fn and fn.name or nil, ui_snippet) then
                    dump.stats.admin_excluded_ui_bindings += 1
                else
                    table.insert(semantic_ui_bindings, {
                        script = path,
                        line = line_number,
                        control = safe_string(control),
                        event = spec.event,
                        function_id = fn and fn.id or nil,
                        function_name = fn and fn.name or nil,
                        nearby_calls = nearby,
                        snippet = ui_snippet,
                    })
                    dump.stats.ui_action_bindings += 1
                end

                break
            end
        end

        if #semantic_ui_bindings >= config.max_ui_bindings then
            break
        end
    end
end

local behavior_map = {}

local ensure_behavior = function(name)
    name = name or "Unknown"
    local behavior = behavior_map[name]

    if not behavior then
        behavior = {
            name = name,
            scripts = {},
            entrypoints = {},
            actions = {},
            remote_protocols = {},
            object_sources = {},
            object_hints = {},
            attributes = {},
            waits = {},
            states = {},
            inbound_signals = {},
            success_signals = {},
            failure_signals = {},
            state_transitions = {},
            ui_bindings = {},
            call_edges = {},
            runtime_function_count = 0,
            metrics = {},
            automation_confidence = "low",
            auto_ready = false,
            internal_or_infrastructure = false,
            _script_seen = {},
            _function_seen = {},
            _remote_seen = {},
            _object_seen = {},
            _attribute_seen = {},
            _wait_seen = {},
            _state_seen = {},
            _signal_seen = {},
            _ui_seen = {},
            _edge_seen = {},
        }
        behavior_map[name] = behavior
        table.insert(semantic_behaviors, behavior)
    end

    return behavior
end

for _, fn in ipairs(semantic_function_list) do
    local system = semantic_system_tag(fn.script)
    local behavior = ensure_behavior(system)

    add_unique_value(behavior.scripts, behavior._script_seen, fn.script)

    if fn.entrypoint then
        add_unique_value(behavior.entrypoints, behavior._function_seen, fn.id)
    end

    if fn.action or fn.exported or #fn.remote_calls > 0 or #fn.runtime_refs > 0 then
        local compact = {
            id = fn.id,
            script = fn.script,
            name = fn.name,
            parameters = fn.parameters,
            action = fn.action,
            exported = fn.exported,
            start_line = fn.start_line,
            end_line = fn.end_line,
            remote_calls = fn.remote_calls,
            inbound_signals = fn.inbound_signals,
            object_sources = fn.object_sources,
            attributes = fn.attributes,
            waits = fn.waits,
            states = fn.states,
            state_assignments = fn.state_assignments,
            runtime_refs = fn.runtime_refs,
            source_excerpt = fn.source_excerpt,
        }

        if #behavior.actions < config.max_behavior_functions then
            table.insert(behavior.actions, compact)
        end
    end

    if #fn.runtime_refs > 0 then
        behavior.runtime_function_count += 1
    end

    merge_unique_values(behavior.object_sources, behavior._object_seen, fn.object_sources, 80)
    merge_unique_values(behavior.attributes, behavior._attribute_seen, fn.attributes, 80)
    merge_unique_values(behavior.waits, behavior._wait_seen, fn.waits, 40)
    merge_unique_values(behavior.states, behavior._state_seen, fn.states, 60)

    for _, transition in ipairs(fn.state_assignments or {}) do
        if #behavior.state_transitions < 60 then
            table.insert(behavior.state_transitions, {
                function_id = fn.id,
                variable = transition.variable,
                value = transition.value,
            })
        end
    end

    for _, remote_call in ipairs(fn.remote_calls) do
        local protocol_id = remote_call.remote_path and ("remote:" .. remote_call.remote_path)
            or (remote_call.framework and remote_call.endpoint and ("framework:" .. remote_call.framework .. ":" .. remote_call.endpoint))
        add_unique_value(behavior.remote_protocols, behavior._remote_seen, protocol_id)
    end

    for _, signal in ipairs(fn.inbound_signals) do
        local key = tostring(signal.remote_path or signal.remote_name or "") .. "|" .. tostring(signal.event or "")
        if not behavior._signal_seen[key] then
            behavior._signal_seen[key] = true
            table.insert(behavior.inbound_signals, signal)

            local signal_text = (tostring(signal.remote_name or signal.remote_path or "") .. " " .. tostring(signal.event or "")):lower()
            if signal_text:find("confirm", 1, true) or signal_text:find("complete", 1, true) or signal_text:find("success", 1, true) or signal_text:find("received", 1, true) or signal_text:find("reward", 1, true) or signal_text:find("caught", 1, true) or signal_text:find("placed", 1, true) then
                table.insert(behavior.success_signals, signal)
            elseif signal_text:find("reject", 1, true) or signal_text:find("fail", 1, true) or signal_text:find("error", 1, true) or signal_text:find("cancel", 1, true) or signal_text:find("missing", 1, true) or signal_text:find("outof", 1, true) then
                table.insert(behavior.failure_signals, signal)
            end
        end
    end

    for _, edge in ipairs(fn.call_edges) do
        local key = fn.id .. "->" .. edge
        if not behavior._edge_seen[key] then
            behavior._edge_seen[key] = true
            table.insert(behavior.call_edges, {from = fn.id, to = edge})
        end
    end
end

for _, binding in ipairs(semantic_ui_bindings) do
    local system = semantic_system_tag(binding.script)
    local behavior = ensure_behavior(system)
    local key = binding.script .. "|" .. tostring(binding.line)

    if not behavior._ui_seen[key] then
        behavior._ui_seen[key] = true
        if #behavior.ui_bindings < 30 then
            table.insert(behavior.ui_bindings, binding)
        end
    end
end


for _, behavior in ipairs(semantic_behaviors) do
    local hint_seen = {}

    for _, source in ipairs(behavior.object_sources) do
        local source_text = tostring(source)
        local leaf = source_text:match("([%a_][%w_]*)$")

        local tag_group = world_tag_groups[source_text] or (leaf and world_tag_groups[leaf])
        if tag_group then
            local key = "tag:" .. tag_group.tag
            if not hint_seen[key] then
                hint_seen[key] = true
                table.insert(behavior.object_hints, {
                    kind = "tag",
                    name = tag_group.tag,
                    count = tag_group.count,
                    samples = tag_group.samples,
                })
            end
        end

        local name_group = world_name_groups[source_text] or (leaf and world_name_groups[leaf])
        if name_group then
            local key = "name:" .. name_group.name
            if not hint_seen[key] then
                hint_seen[key] = true
                table.insert(behavior.object_hints, {
                    kind = "name",
                    name = name_group.name,
                    count = name_group.count,
                    classes = name_group.classes,
                    samples = name_group.samples,
                })
            end
        end

        if #behavior.object_hints >= 30 then
            break
        end
    end
end

local remote_rank_total = 0
local remote_rank_count = 0
local function_rank_total = 0
local object_rank_total = 0
local workflow_rank_total = 0
local auto_ready_count = 0

for _, behavior in ipairs(semantic_behaviors) do
    local internal_hits = 0
    local internal_markers_v6 = {".vendors.", ".packages.", "network", "replica", "cmdr", "tester", "debug", "analytics", "telemetry", "admin", "moderator", "staffpanel", "devpanel", "ownerpanel"}
    for _, script_path in ipairs(behavior.scripts) do
        local lower_path = tostring(script_path):lower()
        for _, marker in ipairs(internal_markers_v6) do
            if lower_path:find(marker, 1, true) then
                internal_hits += 1
                break
            end
        end
    end
    behavior.internal_or_infrastructure = internal_hits > 0 and internal_hits >= math.max(1, math.floor(#behavior.scripts * 0.5))

    local resolved_protocols = 0
    local high_protocols = 0

    for _, protocol_id in ipairs(behavior.remote_protocols) do
        local protocol = protocol_map[protocol_id]
        if protocol then
            resolved_protocols += 1
            if confidence_rank(protocol.confidence) >= confidence_rank("high") then
                high_protocols += 1
            end
        end
    end

    local remote_score = resolved_protocols > 0 and (high_protocols / resolved_protocols) or 0
    local function_score = #behavior.actions > 0 and math.min(1, (behavior.runtime_function_count + #behavior.entrypoints + #behavior.actions * 0.25) / math.max(1, #behavior.actions)) or 0
    local object_score = (#behavior.object_sources > 0 or #behavior.object_hints > 0) and math.min(1, (#behavior.object_sources + #behavior.object_hints * 2) / 6) or 0
    local signal_score = #behavior.inbound_signals > 0 and 1 or 0
    local success_score = (#behavior.success_signals > 0 or #behavior.failure_signals > 0) and 1 or 0
    local edge_score = #behavior.call_edges > 0 and math.min(1, #behavior.call_edges / 3) or 0
    local ui_score = #behavior.ui_bindings > 0 and 1 or 0
    local state_score = #behavior.state_transitions > 0 and math.min(1, #behavior.state_transitions / 4) or 0
    local workflow_score = math.min(1, edge_score * 0.28 + signal_score * 0.18 + success_score * 0.12 + ui_score * 0.12 + state_score * 0.1 + function_score * 0.2)
    local automation_score = remote_score * 0.18 + function_score * 0.24 + object_score * 0.14 + workflow_score * 0.44

    behavior.metrics = {
        remote_resolution = math.floor(remote_score * 1000 + 0.5) / 1000,
        function_resolution = math.floor(function_score * 1000 + 0.5) / 1000,
        object_resolution = math.floor(object_score * 1000 + 0.5) / 1000,
        workflow_resolution = math.floor(workflow_score * 1000 + 0.5) / 1000,
        automation_score = math.floor(automation_score * 1000 + 0.5) / 1000,
    }

    if automation_score >= 0.72 and #behavior.actions >= 2 and not behavior.internal_or_infrastructure then
        behavior.automation_confidence = "high"
        behavior.auto_ready = true
        auto_ready_count += 1
    elseif automation_score >= 0.48 and #behavior.actions >= 1 then
        behavior.automation_confidence = "medium"
    else
        behavior.automation_confidence = "low"
    end

    remote_rank_total += remote_score
    remote_rank_count += 1
    function_rank_total += function_score
    object_rank_total += object_score
    workflow_rank_total += workflow_score

    behavior._script_seen = nil
    behavior._function_seen = nil
    behavior._remote_seen = nil
    behavior._object_seen = nil
    behavior._attribute_seen = nil
    behavior._wait_seen = nil
    behavior._state_seen = nil
    behavior._signal_seen = nil
    behavior._ui_seen = nil
    behavior._edge_seen = nil
end

table.sort(semantic_behaviors, function(a, b)
    if a.auto_ready ~= b.auto_ready then
        return a.auto_ready
    end
    if a.metrics.automation_score ~= b.metrics.automation_score then
        return a.metrics.automation_score > b.metrics.automation_score
    end
    return a.name < b.name
end)

local recipe_from_behavior = function(behavior)
    if not behavior.auto_ready
        or behavior.internal_or_infrastructure
        or is_admin_related(behavior.name, table.concat(behavior.scripts or {}, " ")) then
        return nil
    end

    local steps = {}
    local used = {}

    for _, entry_id in ipairs(behavior.entrypoints) do
        if not used[entry_id] then
            used[entry_id] = true
            table.insert(steps, {type = "entrypoint", function_id = entry_id})
            if #steps >= 8 then
                break
            end
        end
    end

    for _, edge in ipairs(behavior.call_edges) do
        if #steps >= 12 then
            break
        end
        if not used[edge.to] then
            used[edge.to] = true
            table.insert(steps, {type = "call", from = edge.from, function_id = edge.to})
        end
    end

    if #behavior.inbound_signals > 0 and #steps < 14 then
        table.insert(steps, {
            type = "wait_for_signal",
            signals = behavior.inbound_signals,
        })
    end

    if #behavior.waits > 0 and #steps < 15 then
        table.insert(steps, {
            type = "timing",
            waits = behavior.waits,
        })
    end

    return {
        name = "Auto " .. behavior.name,
        behavior = behavior.name,
        confidence = behavior.automation_confidence,
        automation_score = behavior.metrics.automation_score,
        entrypoints = behavior.entrypoints,
        steps = steps,
        object_sources = behavior.object_sources,
        object_hints = behavior.object_hints,
        attributes = behavior.attributes,
        states = behavior.states,
        state_transitions = behavior.state_transitions,
        success_signals = behavior.success_signals,
        failure_signals = behavior.failure_signals,
        remote_protocols = behavior.remote_protocols,
        evidence_note = "Recipe is reconstructed from client function graph, runtime references, UI bindings, object sources, state transitions, remotes, signals, argument provenance, and timing evidence. Validate server-only rules at runtime.",
    }
end

for _, behavior in ipairs(semantic_behaviors) do
    local recipe = recipe_from_behavior(behavior)
    if recipe then
        table.insert(semantic_recipes, recipe)
    end
end

for _, fn in ipairs(semantic_function_list) do
    fn.source_excerpt = nil
end

dump.stats.behavior_count = #semantic_behaviors
dump.stats.automation_recipe_count = #semantic_recipes
dump.stats.auto_ready_behaviors = auto_ready_count

local behavior_divisor = math.max(1, #semantic_behaviors)
local semantic_coverage = {
    remote_resolution = math.floor((remote_rank_total / behavior_divisor) * 10000 + 0.5) / 100,
    function_resolution = math.floor((function_rank_total / behavior_divisor) * 10000 + 0.5) / 100,
    object_resolution = math.floor((object_rank_total / behavior_divisor) * 10000 + 0.5) / 100,
    workflow_resolution = math.floor((workflow_rank_total / behavior_divisor) * 10000 + 0.5) / 100,
    auto_ready_behaviors = auto_ready_count,
    total_behaviors = #semantic_behaviors,
}

dump.READ_ME_FIRST = "This is a Roblox behavior dump. Admin/moderation/staff/developer/owner/Cmdr/tester systems are intentionally excluded and must not be reconstructed. Read ai_handoff and knowledge.behaviors first. Prefer automation_recipes with high workflow confidence. On the first response, summarize detected gameplay behaviors briefly and ask which UI Library the user wants. Do not generate the final script until the user answers the UI Library question."

dump.ai_handoff = {
    purpose = "Use this single JSON file to reconstruct gameplay behavior and generate a complete Luau automation script across different Roblox games without hardcoded game-specific assumptions.",
    preferred_response_language = "Thai",
    excluded_categories = {
        "Admin",
        "Moderation",
        "Staff tools",
        "Developer/owner tools",
        "Cmdr",
        "Tester tools",
        "Privileged control panels",
    },
    privileged_content_policy = "Ignore completely. Do not reconstruct or generate code for excluded privileged systems.",
    authoritative_sections = {
        "knowledge.behaviors",
        "knowledge.automation_recipes",
        "knowledge.functions",
        "knowledge.ui_action_bindings",
        "knowledge.semantic_coverage",
        "knowledge.world",
        "knowledge.protocols",
        "knowledge.systems",
        "knowledge.feature_candidates",
        "scripts",
        "coverage",
        "unresolved",
    },
    first_response = {
        generate_code = false,
        summarize_detected_systems = true,
        ask_exactly_one_primary_question = true,
        primary_question = "ต้องการใช้ UI Library อะไร? ส่งชื่อ, URL หรือ usage example ของ Library มาได้เลย",
        do_not_ask_for = {
            "remote names already present in this dump",
            "remote paths already present in this dump",
            "remote arguments already supported by protocol evidence",
            "module/script paths already present in this dump",
        },
    },
    after_ui_library_response = {
        generate_complete_script = true,
        if_url_is_available = "Read the UI Library documentation/source and follow its API exactly when tooling permits.",
        if_library_api_is_unknown = "Ask only for a minimal usage example of the UI Library, then continue.",
        behavior = {
            "Build the full script, not isolated snippets.",
            "Start from knowledge.automation_recipes and knowledge.behaviors before using raw remote candidates.",
            "Use function source excerpts, call edges, UI bindings, object sources, states, timing, runtime refs, remotes, and argument provenance to reconstruct automation flow.",
            "Use the dump evidence to choose gameplay systems, functions, remotes, methods, arguments, attributes, objects, success signals, and function context.",
            "Prefer high automation/workflow confidence first, then exact/high remote evidence.",
            "Do not invent remote names, remote paths, argument shapes, return values, or server behavior.",
            "Do not claim server-side validation is known when it is not observable from the client.",
            "If a feature has insufficient evidence, omit it or label it unsupported instead of fabricating it.",
            "Do not ask the user to manually locate data that already exists in this JSON.",
            "Use feature_candidates as suggestions, not as proof that every candidate is safe or useful.",
            "Do not expose analytics/infrastructure protocols as normal UI features unless the user explicitly asks for them.",
            "Never use, reconstruct, expose, call, suggest, or automate Admin, moderation, staff, developer, owner, Cmdr, tester, or privileged-control systems. Treat them as excluded even if indirect evidence remains elsewhere in the dump.",
        },
    },
    completion_expectation = {
        output = "one complete Luau script",
        include = {
            "services and variables",
            "required modules when supported by evidence",
            "helper functions",
            "UI construction using the chosen UI Library",
            "toggles/dropdowns/sliders/buttons appropriate to supported gameplay features",
            "automation loops and connections",
            "state management",
            "cleanup/disconnect behavior where needed",
        },
    },
}

dump.generation_preferences = {
    language = "Luau",
    full_script = true,
    human_readable = true,
    comments = false,
    avoid_duplicate_variables = true,
    reuse_services = true,
    reuse_modules = true,
    use_local_functions = true,
    avoid_fake_remote_arguments = true,
    prefer_dump_evidence = true,
    prefer_confidence = {"exact", "high", "framework"},
    preserve_working_game_paths = true,
    ui_library_must_be_chosen_first = true,
    prefer_behavior_recipes = true,
    prefer_runtime_mapped_functions = true,
    require_workflow_evidence_for_automation = true,
}

dump.knowledge = {
    summary = {
        place_id = game.PlaceId,
        game_id = game.GameId,
        place_name = game.Name,
        resolution_percent = dump.coverage.precise_resolution_percent,
        resolved_outbound_calls = dump.coverage.resolved,
        unresolved_outbound_calls = dump.coverage.unresolved,
        protocol_count = #protocol_list,
        system_count = #systems,
        feature_candidate_count = #feature_candidates,
        recommended_feature_candidate_count = recommended_feature_count,
        internal_feature_candidate_count = internal_feature_count,
        ready_for_ai_generation = auto_ready_count > 0,
        auto_ready_behavior_count = auto_ready_count,
        behavior_count = #semantic_behaviors,
        automation_recipe_count = #semantic_recipes,
        workflow_resolution_percent = semantic_coverage.workflow_resolution,
        function_resolution_percent = semantic_coverage.function_resolution,
        object_resolution_percent = semantic_coverage.object_resolution,
        ui_library_required_before_generation = true,
        admin_content_excluded = true,
        admin_excluded_scripts = dump.stats.admin_excluded_scripts,
        admin_excluded_remotes = dump.stats.admin_excluded_remotes,
        admin_excluded_calls = dump.stats.admin_excluded_calls,
        admin_excluded_functions = dump.stats.admin_excluded_functions,
        admin_excluded_ui_bindings = dump.stats.admin_excluded_ui_bindings,
    },
    detected_systems = detected_systems,
    systems = systems,
    protocols = protocol_list,
    feature_candidates = feature_candidates,
    semantic_coverage = semantic_coverage,
    behaviors = semantic_behaviors,
    automation_recipes = semantic_recipes,
    functions = semantic_function_list,
    ui_action_bindings = semantic_ui_bindings,
    world = {
        class_counts = world_class_counts,
        tags = world_tag_list,
        repeated_names = world_name_list,
        catalog = world_catalog,
    },
    confidence_policy = {
        exact = "Directly resolved from a concrete replicated RemoteEvent/RemoteFunction path or direct expression.",
        high = "Resolved through a unique remote-name/suffix alias fallback with strong client-side evidence.",
        framework = "Resolved through a detected networking wrapper endpoint; inspect framework evidence before relying on server semantics.",
        unknown = "Not enough evidence for automatic generation.",
    },
}


local json_safe
json_safe = function(value, seen)
    local value_type = typeof(value)
    if value_type == "nil" then
        return nil
    end
    if value_type == "boolean" then
        return value
    end
    if value_type == "number" then
        return safe_number(value)
    end
    if value_type == "string" then
        return safe_string(value)
    end
    if value_type ~= "table" then
        return safe_string(value)
    end

    seen = seen or {}
    if seen[value] then
        return "<cyclic>"
    end
    seen[value] = true

    local result = {}
    for key, item in pairs(value) do
        local safe_key = type(key) == "number" and key or safe_string(key)
        result[safe_key] = json_safe(item, seen)
    end
    seen[value] = nil
    return result
end

local ok, json = pcall(function()
    return HttpService:JSONEncode(json_safe(dump))
end)
if not ok then return end
local filename = string.format("roblox_ai_dump_v6_%s.json", tostring(game.PlaceId))
local write_ok, write_error = pcall(api.writefile, filename, json)
if not write_ok then return end
print("Done:", filename)
