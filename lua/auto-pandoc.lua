--
-- AUTO PANDOC
--

local fn = vim.fn
local api = vim.api
local cmd = vim.cmd

local ERROR = vim.log.levels.ERROR

local M = {}

---@param string string
local function trim(string)
  return (string:gsub("^%s*(.-)%s*$", "%1"))
end

---@param lines string[]
---@return number|nil #tamaño del indent base (nivel 1), o nil si hay error
local function get_yaml_indent(lines)
  local indent_size = 1000000
  for _, line in ipairs(lines) do
    local indent_pos, _ = string.find(line, "%S")
    if indent_pos == nil then
      vim.notify("auto-pandoc: empty line in YAML header:\n" .. line, ERROR)
      return
    end
    if line:sub(indent_pos, indent_pos) == "#" then
      -- comment line, success
    else
      local local_indent_size = (indent_pos - 1)
      if indent_size > local_indent_size then
        indent_size = local_indent_size
      end
    end
  end
  return indent_size
end

---Parsea una línea del bloque YAML en {key, value, indent}.
---NO decide a qué nivel pertenece -- eso lo hace get_args, que tiene
---el contexto (grupo padre) necesario para distinguirlo.
---@param line string
---@return table|false|nil
--  false -> línea de comentario, ignorar (no es error)
--  nil   -> error de parseo (ya notificado con vim.notify)
--  table -> { key, value, indent }
local function parse_line(line)
  local indent_pos, _ = string.find(line, "%S")
  if indent_pos == nil then
    vim.notify("auto-pandoc: empty line in YAML header:\n" .. line, ERROR)
    return
  end
  if line:sub(indent_pos, indent_pos) == "#" then
    return false -- comment line, ignorar (no es un error)
  end

  local indent = indent_pos - 1
  line = trim(line)
  -- ".-" (no-greedy) en vez de ".*": corta en el PRIMER ":" de la línea,
  -- para no romper valores que a su vez contienen ":" (rutas Windows,
  -- "geometry: margin=1in", etc.)
  local key, value = string.match(line, "^(.-):%s*(.*)")
  if key == nil then
    vim.notify("auto-pandoc: XXXcould not parse line (missing ':'):\n" .. line, ERROR)
    return
  end

  key = trim(key)
  if key:sub(1, 2) == "- " then
    key = key:sub(3)
  end
  -- remove inline comments
  if value:find("#") ~= nil then
    local comment_pos, _ = value:find("#")
    value = value:sub(1, comment_pos - 1)
  end
  value = trim(value)
  return { key = key, value = value, indent = indent }
end

---Combina una clave de grupo (nivel 1, ej. "variable") con un hijo de
---nivel 2 (ej. "geometry" = "margin=1in") en un único par listo para
---convertirse en flag de pandoc.
---Pandoc acepta ":" o "=" para separar KEY de VAL en -V/--variable y
-----metadata (ver Pandoc User's Guide: "-V KEY[=VAL] ... Either : or =
---may be used to separate KEY from VAL" -- https://pandoc.org/MANUAL.html).
---@param parent_key string
---@param child_key string
---@param child_value string
---@return string, string
local function merge_nested(parent_key, child_key, child_value)
  return parent_key, child_key .. ":" .. child_value
end

---Recorre las líneas ya delimitadas del bloque `pandoc_:` y arma la
---lista ordenada de {key, value} que luego se convierte en flags.
---Soporta 1 o 2 niveles de indentación:
---  - nivel 1 con value  -> entrada normal ("output: .pdf")
---  - nivel 1 sin value  -> abre un grupo ("variable:")
---  - nivel 2            -> hijo de ese grupo, se fusiona con merge_nested
---Las claves repetidas (en cualquier nivel) SE CONSERVAN todas, en vez
---de sobreescribirse, para poder repetir flags como --filter o --variable.
---@param lines string[]
---@param base_indent number
---@return table[]|nil
local function build_entries(lines, base_indent)
  local entries = {}
  local current_parent = nil
  local current_child_indent = nil

  for _, v in ipairs(lines) do
    local kv = parse_line(v)
    if kv == false then
      -- comentario: ignorar y seguir
    elseif kv == nil then
      return nil -- error ya notificado dentro de parse_line
    elseif kv.indent == base_indent then
      -- nivel 1
      current_parent = nil
      current_child_indent = nil
      if kv.value ~= "" then
        table.insert(entries, { key = kv.key, value = kv.value })
      else
        current_parent = kv.key -- ej. "variable:" -- abre un grupo
      end
    elseif kv.indent > base_indent then
      -- nivel 2 (hijo del último grupo abierto)
      if not current_parent then
        vim.notify("auto-pandoc: nested option without a parent group:\n" .. v, ERROR)
        return nil
      end
      if current_child_indent == nil then
        current_child_indent = kv.indent
      elseif kv.indent ~= current_child_indent then
        vim.notify("auto-pandoc: inconsistent or too-deep indentation:\n" .. v, ERROR)
        return nil
      end
      local key, value = merge_nested(current_parent, kv.key, kv.value)
      table.insert(entries, { key = key, value = value })
    else
      vim.notify("auto-pandoc: YAML indentation error:\n" .. v, ERROR)
      return nil
    end
  end
  return entries
end

---Gets arguments from the YAML header and gives errors when options aren't correct
---@return table|nil #Table if success, nil otherwise
local function get_args()
  local cur_pos = api.nvim_win_get_cursor(0)
  local lnr_from = fn.search([[^pandoc_:$]])
  if lnr_from == 0 then
    vim.notify("auto-pandoc: options missing!", ERROR)
    return
  end
  local lnr_until = fn.search([[^\S]]) - 1
  local lines = api.nvim_buf_get_lines(0, lnr_from, lnr_until, true)
  local base_indent = get_yaml_indent(lines)
  if not base_indent then
    return
  end

  local entries = build_entries(lines, base_indent)
  api.nvim_win_set_cursor(0, cur_pos)
  if not entries then
    return
  end

  local output_value = nil
  for _, e in ipairs(entries) do
    if e.key == "output" then
      output_value = e.value
    end
  end
  if output_value == nil then
    vim.notify("auto-pandoc: field `output` not specified, export failed", ERROR)
    return
  end
  if output_value:sub(1, 1) == "." then
    output_value = fn.expand([[%:p:r]]) .. output_value
  end

  local args = {}
  for _, e in ipairs(entries) do
    local key, value = e.key, e.value
    if key == "output" then
      value = output_value
    end
    if value == "true" then
      table.insert(args, "--" .. key)
    else
      table.insert(args, "--" .. key .. "=" .. value)
    end
  end
  table.insert(args, fn.expand([[%:p]]))
  return args
end

---Main function to run pandoc
function M.run_pandoc()
  local cwd = fn.getcwd()
  cmd([[:cd %:p:h]])
  local args = get_args()
  if args then
    vim.notify("auto-pandoc: conversion started")
    vim.system(
      { "pandoc", unpack(args) },
      {},
      function(result)
        vim.schedule(function()
          if result.code == 0 then
            vim.notify("auto-pandoc: conversion complete")
          else
            local err_msg = result.stderr and result.stderr:match("[^\r\n]+") or "unknown error"
            vim.notify("auto-pandoc: conversion error: " .. err_msg, ERROR)
          end
        end)
      end
    )
  end
  cmd(":cd " .. cwd)
end

return M
