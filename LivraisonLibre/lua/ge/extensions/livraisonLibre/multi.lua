-- Livraison Libre - multijoueur (BeamMP)
-- En partie BeamMP, les joueurs qui lancent les livraisons forment un groupe : le premier (le chef) choisit
-- chaque livraison (véhicule, départ, destination) et le serveur la transmet à tous. Chacun a sa place, côte
-- à côte, au départ comme à l'arrivée ; la livraison suivante part quand tout le groupe a fini.
-- Le plugin serveur (Resources/Server/LivraisonLibre/main.lua) tient le groupe et relaie les messages.
-- Ce module : places côte à côte, messages et classement (purs, testables hors du jeu), et accès à BeamMP,
-- toujours protégé (le mod marche aussi sans BeamMP).

local M = {}

M.PROTO = 2
M.MAX_SLOTS = 8 -- joueurs par groupe (places calculées pour chaque livraison)
-- messages : client -> serveur, puis serveur -> client
M.EV = {
  join = 'LL_join', leave = 'LL_leave', propose = 'LL_propose', done = 'LL_done',
  players = 'LL_players', invite = 'LL_invite',
  group = 'LL_group', round = 'LL_round', result = 'LL_result', roundEnd = 'LL_roundEnd', full = 'LL_full',
  playerList = 'LL_playerList', invited = 'LL_invited',
}

local floor, max, abs = math.floor, math.max, math.abs

-- variable globale de BeamMP ou du jeu (nil si absente, sans erreur)
local function global(name)
  local v = rawget(_G, name)
  if v == nil then
    local ok, x = pcall(function() return _G[name] end)
    if ok then v = x end
  end
  return v
end

-- Partie BeamMP en cours ?
function M.isSession()
  local cn = global('MPCoreNetwork')
  if type(cn) ~= 'table' or type(cn.isMPSession) ~= 'function' then return false end
  local ok, v = pcall(cn.isMPSession)
  return ok and v == true
end

-- identifiant du joueur sur le serveur, et son pseudo
function M.myId()
  local c = global('MPConfig')
  if type(c) ~= 'table' or type(c.getPlayerServerID) ~= 'function' then return nil end
  local ok, v = pcall(c.getPlayerServerID)
  return ok and tonumber(v) or nil
end

function M.myName()
  local c = global('MPConfig')
  if type(c) ~= 'table' or type(c.getNickname) ~= 'function' then return nil end
  local ok, v = pcall(c.getNickname)
  return (ok and type(v) == 'string') and v or nil
end

-- véhicule à soi (en partie BeamMP, ceux des autres joueurs sont aussi dans le monde)
function M.isOwn(vid)
  if not M.isSession() then return true end
  local vg = global('MPVehicleGE')
  if type(vg) ~= 'table' or type(vg.isOwn) ~= 'function' then return true end
  local ok, v = pcall(vg.isOwn, vid)
  return not ok or v ~= false
end

-- message au serveur (table encodée en JSON)
function M.send(name, tbl)
  local f, enc = global('TriggerServerEvent'), global('jsonEncode')
  if type(f) ~= 'function' or type(enc) ~= 'function' then return false end
  local okE, data = pcall(enc, tbl or {})
  if not okE or type(data) ~= 'string' then return false end
  return (pcall(f, name, data))
end

-- écoute les messages du serveur ; handlers = {nom = function(table)}. Au rechargement du mod, les
-- anciennes fonctions (gardées par BeamMP) sont remplacées.
local TAG = 'livraisonLibre'
function M.listen(handlers)
  local add, rem, dec = global('AddEventHandler'), global('RemoveEventHandler'), global('jsonDecode')
  if type(add) ~= 'function' or type(dec) ~= 'function' then return false end
  local again = global('__livraisonLibreMp')
  for name, fn in pairs(handlers) do
    if again and type(rem) == 'function' then pcall(rem, name, TAG) end
    add(name, function(data)
      local ok, t = pcall(dec, data)
      if ok and type(t) == 'table' then fn(t) end
    end, TAG)
  end
  rawset(_G, '__livraisonLibreMp', true)
  return true
end

---------------------------------------------------------------------------
-- places côte à côte
---------------------------------------------------------------------------
local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

-- zone décalée : side le long de la droite de la zone, back vers l'arrière (contre son avant)
local function shifted(base, side, back, fx, fy, fz)
  fx, fy, fz = fx or base.fx, fy or base.fy, fz or base.fz
  local z = copy(base)
  z.x = base.x + base.rx * side - fx * back
  z.y = base.y + base.ry * side - fy * back
  z.z = base.z + base.rz * side - fz * back
  return z
end

-- deux zones qui se chevauchent (rectangles, dans le repère de a)
function M.overlap(a, b, margin)
  margin = margin or 0.1
  local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
  local along = abs(dx * a.fx + dy * a.fy + dz * a.fz)
  local side = abs(dx * a.rx + dy * a.ry + dz * a.rz)
  if abs(dz) > 3 then return false end
  return along < (a.l + b.l) * 0.5 - margin and side < (a.w + b.w) * 0.5 - margin
end

local function free(z, zones)
  for _, o in ipairs(zones) do if M.overlap(o, z) then return false end end
  return true
end

-- Places de n joueurs à partir de la zone du chef (base, calculée par locations.zoneFor pour
-- l'emplacement c) :
-- - bord de route : à côté, vers l'autre côté de la route, tant qu'il reste de la largeur ; puis derrière ;
-- - place de parking (site du niveau) : les places voisines du même parking (opts.near : zones des places
--   proches, triées par distance), sinon à côté, une largeur de place plus loin ;
-- - allée : derrière, vers la rue ; point perso : derrière.
-- opts.gap : écart entre deux zones (m). Renvoie n zones ; la 1re est base.
function M.slotZones(base, c, n, opts)
  opts = opts or {}
  local gap = opts.gap or 0.6
  local zones = {base}
  if n <= 1 then return zones end
  if c and c.kind == 'road' and c.half then
    -- place de la zone par rapport au milieu de la route, le long de sa droite
    local s0 = (base.x - c.x) * base.rx + (base.y - c.y) * base.ry + (base.z - c.z) * base.rz
    local smax = max(0, c.half - base.w * 0.5 - 0.15)
    local dir = (s0 < -0.05) and 1 or -1
    local step = base.w + gap
    local cols = {0}
    for j = 1, M.MAX_SLOTS - 1 do
      if abs(s0 + dir * j * step) > smax + 1e-6 then break end
      cols[#cols + 1] = dir * j * step
    end
    for k = 2, n do
      local i = k - 1
      zones[k] = shifted(base, cols[i % #cols + 1], floor(i / #cols) * (base.l + gap * 2))
    end
    return zones
  end
  if c and c.spotW and not c.deadEnd then
    local near, ni = opts.near or {}, 1
    local width = max(c.spotW, base.w + gap)
    for k = 2, n do
      local z
      while near[ni] and not z do
        if free(near[ni], zones) then z = near[ni] end
        ni = ni + 1
      end
      -- plus de place voisine connue : à côté, en alternant les côtés
      for m = 1, 2 * M.MAX_SLOTS do
        if z then break end
        local cand = shifted(base, ((m % 2 == 1) and 1 or -1) * floor((m + 1) / 2) * width, 0)
        if free(cand, zones) then z = cand end
      end
      zones[k] = z
    end
    return zones
  end
  -- allée : vers la rue (contre le sens de l'allée, même si la voiture est tournée vers la rue)
  local fx, fy, fz
  if c and c.deadEnd and c.fx then fx, fy, fz = c.fx, c.fy, c.fz end
  for k = 2, n do zones[k] = shifted(base, 0, (k - 1) * (base.l + gap * 2), fx, fy, fz) end
  return zones
end

---------------------------------------------------------------------------
-- messages
---------------------------------------------------------------------------
-- emplacement de livraison réduit à des nombres et du texte (le graphe routier est recalculé chez chacun)
local CAND_FIELDS = {'id', 'kind', 'label', 'name', 'x', 'y', 'z', 'fx', 'fy', 'fz', 'ux', 'uy', 'uz', 'half',
  'oneWay', 'fwdSign', 'highway', 'deadEnd', 'depth', 'edgeLen', 'spotW', 'spotL', 'drv', 'pointId'}
local ZONE_FIELDS = {'x', 'y', 'z', 'fx', 'fy', 'fz', 'rx', 'ry', 'rz', 'ux', 'uy', 'uz', 'w', 'l', 'dirSign', 'flipped'}

local function pack(t, fields)
  if type(t) ~= 'table' then return nil end
  local o = {}
  for _, k in ipairs(fields) do
    local v = t[k]
    local tv = type(v)
    if (tv == 'number' and v == v and v > -math.huge and v < math.huge) or tv == 'string' or tv == 'boolean' then o[k] = v end
  end
  return o
end

function M.packCand(c) return pack(c, CAND_FIELDS) end
function M.packZone(z) return pack(z, ZONE_FIELDS) end

-- zone reçue : complète et en nombres
function M.unpackZone(z)
  if type(z) ~= 'table' then return nil end
  for _, k in ipairs({'x', 'y', 'z', 'fx', 'fy', 'fz', 'rx', 'ry', 'rz', 'w', 'l'}) do
    if type(z[k]) ~= 'number' or z[k] ~= z[k] then return nil end
  end
  local o = copy(z)
  o.ux, o.uy, o.uz = tonumber(z.ux) or 0, tonumber(z.uy) or 0, tonumber(z.uz) or 1
  return o
end

-- Classement de la livraison du groupe : livrés (du plus rapide au plus lent), puis ratés et passés, puis
-- ceux encore en route. members = {{id, name}}, results = {[id en texte] = {result, time}}
function M.ranking(members, results, myId)
  local out = {}
  for _, m in ipairs(members or {}) do
    local id = tonumber(m.id)
    local r = results and results[tostring(id)] or nil
    out[#out + 1] = {id = id, name = m.name or ('Joueur ' .. tostring(id)), me = (id ~= nil and id == myId) or nil,
      result = r and r.result or nil, time = r and tonumber(r.time) or nil}
  end
  local function key(p)
    if p.result == 'Livrée' then return 0 end
    if p.result then return 1 end
    return 2
  end
  table.sort(out, function(a, b)
    local ka, kb = key(a), key(b)
    if ka ~= kb then return ka < kb end
    if ka == 0 and a.time and b.time and a.time ~= b.time then return a.time < b.time end
    return (a.name or '') < (b.name or '')
  end)
  local rank = 0
  for _, p in ipairs(out) do
    if p.result == 'Livrée' then rank = rank + 1; p.rank = rank end
  end
  return out
end

return M
