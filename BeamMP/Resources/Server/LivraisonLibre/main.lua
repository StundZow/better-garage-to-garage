-- Livraison Libre - plugin serveur BeamMP
-- Les joueurs qui lancent les livraisons forment un groupe. Le chef (le premier arrivé) choisit chaque
-- livraison ; ce plugin la transmet à tout le groupe avec la place de chacun (départs et arrivées côte à
-- côte). Quand tout le monde a fini (livrée, ratée ou passée), le chef lance la suivante.
-- Installation sur le serveur : ce dossier dans Resources/Server/ (Resources/Server/LivraisonLibre/main.lua)
-- et LivraisonLibre.zip dans Resources/Client/ (le serveur l'envoie aux joueurs).

local PROTO = 1     -- version des messages (doit être la même que celle du mod)
local MAX_SLOTS = 8 -- joueurs par groupe

local members = {}  -- [id] = {name, order}
local order = 0
local leader = nil
local round = nil   -- {id, mission, slots = {[id] = place}, pending = {[id] = true}, results = {}, ended}
local roundSeq = 0

local function decode(data)
  if type(data) ~= 'string' or data == '' then return nil end
  local ok, t = pcall(Util.JsonDecode, data)
  if ok and type(t) == 'table' then return t end
  return nil
end

local function send(id, event, tbl)
  local ok, data = pcall(Util.JsonEncode, tbl)
  if ok and data then pcall(MP.TriggerClientEvent, id, event, data) end
end

-- membres dans l'ordre d'arrivée
local function list()
  local out = {}
  for id, m in pairs(members) do out[#out + 1] = {id = id, name = m.name, order = m.order} end
  table.sort(out, function(a, b) return a.order < b.order end)
  return out
end

local function count()
  local n = 0
  for _ in pairs(members) do n = n + 1 end
  return n
end

local function broadcast(event, tbl)
  for id in pairs(members) do send(id, event, tbl) end
end

local function sendGroup()
  local ms = {}
  for _, m in ipairs(list()) do ms[#ms + 1] = {id = m.id, name = m.name} end
  broadcast('LL_group', {leader = leader, members = ms, round = (round and not round.ended) and round.id or nil})
end

local function sendRound(id)
  send(id, 'LL_round', {round = round.id, leader = leader, slot = round.slots[id], mission = round.mission})
end

local function freeSlot()
  local used = {}
  for _, s in pairs(round.slots) do used[s] = true end
  for s = 1, MAX_SLOTS do if not used[s] then return s end end
  return nil
end

-- tout le groupe a fini : le chef peut lancer la livraison suivante
local function checkEnd()
  if round and not round.ended and next(round.pending) == nil then
    round.ended = true
    broadcast('LL_roundEnd', {round = round.id, results = round.results})
  end
end

local function remove(id)
  if not id or not members[id] then return end
  members[id] = nil
  if round then
    round.pending[id] = nil
    round.slots[id] = nil
  end
  if leader == id then
    -- le suivant arrivé devient chef
    local l = list()
    leader = l[1] and l[1].id or nil
  end
  if not next(members) then round, leader = nil, nil end
  sendGroup()
  checkEnd()
end

-- un joueur lance les livraisons : il rejoint le groupe (et la livraison en cours, à la place suivante)
function LivraisonLibre_join(id, data)
  id = tonumber(id)
  if not id then return end
  local d = decode(data) or {}
  if tonumber(d.v) ~= PROTO then
    MP.SendChatMessage(id, 'Livraison Libre : la version du mod ne correspond pas à celle du plugin du serveur.')
  end
  if not members[id] then
    if count() >= MAX_SLOTS then
      send(id, 'LL_full', {max = MAX_SLOTS})
      return
    end
    order = order + 1
    members[id] = {name = MP.GetPlayerName(id) or d.name or ('Joueur ' .. id), order = order}
  end
  if not leader or not members[leader] then leader = id end
  sendGroup()
  if round and not round.ended then
    if not round.slots[id] then
      round.slots[id] = freeSlot()
      round.pending[id] = true
    end
    if round.slots[id] then sendRound(id) end
  end
end

-- un joueur arrête les livraisons
function LivraisonLibre_leave(id, data)
  remove(tonumber(id))
end

-- le chef envoie la livraison suivante : place 1 pour lui, puis dans l'ordre d'arrivée
function LivraisonLibre_propose(id, data)
  id = tonumber(id)
  if not id or id ~= leader then return end
  local mission = decode(data)
  if not mission then return end
  roundSeq = roundSeq + 1
  round = {id = roundSeq, mission = mission, slots = {[leader] = 1}, pending = {[leader] = true}, results = {}, ended = false}
  local k = 1
  for _, m in ipairs(list()) do
    if m.id ~= leader then
      k = k + 1
      round.slots[m.id] = k
      round.pending[m.id] = true
    end
  end
  sendGroup()
  for mid in pairs(members) do sendRound(mid) end
end

-- un joueur a fini sa livraison (livrée, ratée, passée)
function LivraisonLibre_done(id, data)
  id = tonumber(id)
  local d = decode(data) or {}
  if not id or not round or round.ended or tonumber(d.round) ~= round.id or not round.pending[id] then return end
  round.pending[id] = nil
  local res = {id = id, name = members[id] and members[id].name or MP.GetPlayerName(id), result = tostring(d.result or '?'),
    time = tonumber(d.time)}
  round.results[tostring(id)] = res
  broadcast('LL_result', {round = round.id, id = res.id, name = res.name, result = res.result, time = res.time})
  checkEnd()
end

function LivraisonLibre_disconnect(id)
  remove(tonumber(id))
end

MP.RegisterEvent('LL_join', 'LivraisonLibre_join')
MP.RegisterEvent('LL_leave', 'LivraisonLibre_leave')
MP.RegisterEvent('LL_propose', 'LivraisonLibre_propose')
MP.RegisterEvent('LL_done', 'LivraisonLibre_done')
MP.RegisterEvent('onPlayerDisconnect', 'LivraisonLibre_disconnect')
print('[LivraisonLibre] plugin serveur chargé (messages v' .. PROTO .. ')')
