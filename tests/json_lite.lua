-- JSON minimal pour les tests : remplace jsonEncode / jsonDecode du jeu et Util.JsonEncode / JsonDecode du
-- serveur BeamMP. Tableaux (clés 1..n) ou objets (clés texte) ; les nombres gardent toute leur précision.
local M = {}

local ESC = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
local function encStr(s)
  return '"' .. (s:gsub('[%c"\\]', function(c) return ESC[c] or string.format('\\u%04x', c:byte()) end)) .. '"'
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

function M.encode(v)
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then
    assert(v == v and v > -math.huge and v < math.huge, 'nombre non fini')
    if v % 1 == 0 and math.abs(v) < 2 ^ 53 then return string.format('%.0f', v) end
    return string.format('%.17g', v)
  end
  if t == 'string' then return encStr(v) end
  if t == 'table' then
    local parts = {}
    if isArray(v) then
      for i = 1, #v do parts[i] = M.encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, x in pairs(v) do
      assert(type(k) == 'string', 'clé non texte dans un objet JSON : ' .. tostring(k))
      parts[#parts + 1] = encStr(k) .. ':' .. M.encode(x)
    end
    table.sort(parts)
    return '{' .. table.concat(parts, ',') .. '}'
  end
  error('valeur non encodable en JSON : ' .. t)
end

function M.decode(s)
  local pos = 1
  local function ws() pos = s:find('[^ \t\r\n]', pos) or (#s + 1) end
  local value
  local function str()
    pos = pos + 1
    local out = {}
    while true do
      local c = s:sub(pos, pos)
      if c == '' then error('texte JSON non terminé') end
      if c == '"' then pos = pos + 1 break end
      if c == '\\' then
        local e = s:sub(pos + 1, pos + 1)
        local map = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
        if e == 'u' then
          local code = tonumber(s:sub(pos + 2, pos + 5), 16)
          if code < 0x80 then out[#out + 1] = string.char(code)
          elseif code < 0x800 then out[#out + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
          else out[#out + 1] = string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64) end
          pos = pos + 6
        else
          out[#out + 1] = map[e] or e
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  value = function()
    ws()
    local c = s:sub(pos, pos)
    if c == '{' then
      pos = pos + 1
      local o = {}
      ws()
      if s:sub(pos, pos) == '}' then pos = pos + 1 return o end
      while true do
        ws()
        local k = str()
        ws()
        assert(s:sub(pos, pos) == ':', 'JSON : « : » attendu')
        pos = pos + 1
        o[k] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == '}' then return o end
        assert(d == ',', 'JSON : « , » attendu')
      end
    elseif c == '[' then
      pos = pos + 1
      local a = {}
      ws()
      if s:sub(pos, pos) == ']' then pos = pos + 1 return a end
      while true do
        a[#a + 1] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == ']' then return a end
        assert(d == ',', 'JSON : « , » attendu')
      end
    elseif c == '"' then
      return str()
    elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
    end
    local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
    assert(num and num ~= '', 'JSON invalide à la position ' .. pos)
    pos = pos + #num
    return tonumber(num)
  end
  local ok, res = pcall(value)
  if not ok then return nil end
  return res
end

return M
