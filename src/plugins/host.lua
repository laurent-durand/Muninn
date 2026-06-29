-- src/plugins/host.lua
-- Muninn plugin host — Lua 5.4.
-- Scans configured plugin directories, loads each *.lua file in a sandboxed
-- environment, and invokes lifecycle hooks on each metric snapshot.

local json = require("dkjson") or require("cjson") or (function()
  -- minimal JSON fallback (numbers + strings only)
  return {
    decode = function(s) return load("return " .. s:gsub(':', '='):gsub('"(%w+)"=', '%1='))() end,
    encode = function(t)
      local parts = {}
      for k, v in pairs(t) do
        local vs = type(v) == "number" and tostring(v) or ('"' .. tostring(v) .. '"')
        parts[#parts+1] = '"' .. k .. '":' .. vs
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end,
  }
end)()

-- ─── Sandbox ─────────────────────────────────────────────────────────────────

local SAFE_ENV = {
  -- allowed stdlib
  math     = math,
  string   = string,
  table    = table,
  pairs    = pairs,
  ipairs   = ipairs,
  tonumber = tonumber,
  tostring = tostring,
  type     = type,
  select   = select,
  unpack   = table.unpack,
  print    = print,
  -- Muninn API injected below
}

function SAFE_ENV.emit_alert(severity, message, labels)
  local alert = {
    type     = "alert",
    severity = severity or "info",
    message  = message  or "",
    labels   = labels   or {},
    fired_at = os.time(),
  }
  io.write(json.encode(alert) .. "\n")
  io.flush()
end

function SAFE_ENV.emit_metric(name, value, tags)
  local m = { type = "custom_metric", name = name, value = value, tags = tags or {} }
  io.write(json.encode(m) .. "\n")
  io.flush()
end

-- ─── Plugin registry ─────────────────────────────────────────────────────────

local plugins = {}

local function load_plugin(path)
  local chunk, err = loadfile(path)
  if not chunk then
    io.stderr:write("plugin load error: " .. path .. ": " .. tostring(err) .. "\n")
    return nil
  end

  -- give the chunk a fresh copy of SAFE_ENV
  local env = setmetatable({}, { __index = SAFE_ENV })
  setfenv(chunk, env)   -- Lua 5.1/5.2 style; 5.4 uses upvalue swap

  local ok, result = pcall(chunk)
  if not ok then
    io.stderr:write("plugin init error: " .. path .. ": " .. tostring(result) .. "\n")
    return nil
  end

  -- Plugin module must return a table with lifecycle hooks
  if type(result) ~= "table" then
    io.stderr:write("plugin " .. path .. " did not return a table\n")
    return nil
  end

  io.stderr:write("loaded plugin: " .. (result.name or path) .. "\n")
  return result
end

local function scan_dir(dir)
  local handle = io.popen('find "' .. dir .. '" -maxdepth 1 -name "*.lua" 2>/dev/null')
  if not handle then return end
  for path in handle:lines() do
    local plugin = load_plugin(path)
    if plugin then plugins[#plugins+1] = plugin end
  end
  handle:close()
end

-- ─── Lifecycle dispatch ───────────────────────────────────────────────────────

local function call_hook(hook_name, ...)
  for _, plugin in ipairs(plugins) do
    local hook = plugin[hook_name]
    if type(hook) == "function" then
      local ok, err = pcall(hook, ...)
      if not ok then
        io.stderr:write("plugin " .. (plugin.name or "?") ..
                        " hook " .. hook_name .. " error: " .. tostring(err) .. "\n")
      end
    end
  end
end

-- ─── Main loop ────────────────────────────────────────────────────────────────

local function main()
  -- Load plugins from configured dirs (default: ./plugins/enabled/)
  local dirs = arg[1] and { arg[1] } or { "./plugins/enabled", "/etc/muninn/plugins" }
  for _, dir in ipairs(dirs) do scan_dir(dir) end

  io.stderr:write(string.format("muninn-plugins: %d plugin(s) loaded\n", #plugins))
  call_hook("on_init")

  for line in io.lines() do
    local snap, err = json.decode(line)
    if snap then
      call_hook("on_snapshot", snap)
    else
      io.stderr:write("json decode error: " .. tostring(err) .. "\n")
    end
  end

  call_hook("on_shutdown")
end

main()
