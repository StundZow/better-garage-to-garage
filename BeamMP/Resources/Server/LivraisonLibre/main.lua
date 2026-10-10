-- Livraison Libre - plugin serveur BeamMP
-- Les joueurs qui lancent les livraisons forment un groupe. Le chef (le premier arrivé) choisit chaque
-- livraison ; ce plugin la transmet à tout le groupe avec la place de chacun (départs et arrivées côte à
-- côte). Quand tout le monde a fini (livrée, ratée ou passée), le chef lance la suivante.
-- Un joueur peut aussi choisir (onglet Plus de l'app) les joueurs qui reçoivent ses livraisons : ce plugin
-- leur transmet l'invitation, et leur mod lance les livraisons tout seul. Tout le groupe joue avec les réglages
-- du chef (envoyés avec chaque livraison, et à chaque changement) ; un invité s'arrête quand son hôte s'arrête.
-- Installation sur le serveur : ce dossier dans Resources/Server/ (Resources/Server/LivraisonLibre/main.lua)
-- et LivraisonLibre.zip dans Resources/Client/ (le serveur l'envoie aux joueurs).

local PROTO = 3     -- version des messages (doit être la même que celle du mod)
local MAX_SLOTS = 8 -- joueurs par groupe

local members = {}  -- [id] = {name, order, invitedBy = id de l'hôte qui l'a invité}
local order = 0
local leader = nil
local round = nil   -- {id, mission, slots = {[id] = place}, pending = {[id] = true}, results = {}, ended}
local roundSeq = 0
local invited = {}  -- [id] = id de l'hôte : invité, pas encore dans le groupe (le chef l'attend pour la 1re livraison)

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
  local ms, inv = {}, {}
  for _, m in ipairs(list()) do ms[#ms + 1] = {id = m.id, name = m.name} end
  for id in pairs(invited) do inv[#inv + 1] = MP.GetPlayerName(id) or ('Joueur ' .. id) end
  table.sort(inv)
  broadcast('LL_group', {leader = leader, members = ms, invited = inv,
    round = (round and not round.ended) and round.id or nil})
end

-- joueurs connectés, et qui est dans le groupe (pour choisir avec qui jouer)
local function players(except)
  local out = {}
  local ok, ps = pcall(MP.GetPlayers)
  if ok and type(ps) == 'table' then
    for pid, name in pairs(ps) do
      pid = tonumber(pid)
      if pid and pid ~= except then
        out[#out + 1] = {id = pid, name = tostring(name), inGroup = members[pid] ~= nil}
      end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- liste envoyée à un joueur, ou à tout le monde (-1)
local function sendPlayers(to, except)
  send(to or -1, 'LL_playerList', {players = players(except)})
end

-- invitations de fromId (pseudos) : les joueurs connectés qui ne sont pas dans le groupe la reçoivent, et
-- leur mod lance les livraisons
local function inviteNames(fromId, names)
  if type(names) ~= 'table' then return 0 end
  local wanted, n = {}, 0
  for _, name in pairs(names) do wanted[tostring(name)] = true end
  local from = MP.GetPlayerName(fromId) or ('Joueur ' .. fromId)
  for _, p in ipairs(players()) do
    if p.id ~= fromId and wanted[p.name] and not members[p.id] then
      invited[p.id] = fromId
      send(p.id, 'LL_invited', {from = fromId, name = from})
      n = n + 1
    end
  end
  return n
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
  if not id then return end
  local wasInvited = invited[id]
  invited[id] = nil
  if not members[id] then
    if wasInvited and next(members) then sendGroup() end -- le chef n'attend plus cet invité
    return
  end
  members[id] = nil
  if round then
    round.pending[id] = nil
    round.slots[id] = nil
  end
  -- les joueurs qu'il a invités s'arrêtent avec lui (ils jouaient avec ses réglages), et ceux qu'eux ont invités
  local gone, i = {id}, 1
  while gone[i] do
    local host = gone[i]
    for pid, h in pairs(invited) do
      if h == host then invited[pid] = nil end -- invitations pas encore acceptées : annulées
    end
    for mid, m in pairs(members) do
      if m.invitedBy == host then
        members[mid] = nil
        invited[mid] = nil
        if round then
          round.pending[mid] = nil
          round.slots[mid] = nil
        end
        gone[#gone + 1] = mid
        send(mid, 'LL_stop', {by = MP.GetPlayerName(host) or ('Joueur ' .. host)})
      end
    end
    i = i + 1
  end
  if leader and not members[leader] then
    -- le suivant arrivé devient chef
    local l = list()
    leader = l[1] and l[1].id or nil
  end
  if not next(members) then round, leader, invited = nil, nil, {} end
  sendGroup()
  checkEnd()
end

local function removeAndList(id, gone)
  remove(id)
  sendPlayers(-1, gone and id or nil)
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
    members[id] = {name = MP.GetPlayerName(id) or d.name or ('Joueur ' .. id), order = order, invitedBy = invited[id]}
  end
  invited[id] = nil
  if not leader or not members[leader] then leader = id end
  inviteNames(id, d.invite) -- joueurs choisis par celui qui arrive (avant l'envoi du groupe : le chef les attend)
  sendGroup()
  sendPlayers()
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
  removeAndList(tonumber(id))
end

-- un joueur demande la liste des joueurs connectés
function LivraisonLibre_players(id, data)
  id = tonumber(id)
  if id then sendPlayers(id) end
end

-- un joueur invite des joueurs (par leur pseudo) : ceux qui ne sont pas encore dans le groupe reçoivent
-- l'invitation, et leur mod lance les livraisons
function LivraisonLibre_invite(id, data)
  id = tonumber(id)
  local d = decode(data) or {}
  if not id or type(d.names) ~= 'table' then return end
  if inviteNames(id, d.names) > 0 and next(members) then sendGroup() end
end

function LivraisonLibre_playerJoin(id)
  sendPlayers()
end

-- le chef a changé ses réglages pendant les livraisons : envoyés tout de suite au reste du groupe (et gardés
-- avec la livraison en cours, pour ceux qui la rejoignent)
function LivraisonLibre_cfg(id, data)
  id = tonumber(id)
  if not id or id ~= leader then return end
  local d = decode(data)
  if not d or type(d.cfg) ~= 'table' then return end
  if round and type(round.mission) == 'table' then round.mission.cfg = d.cfg end
  for mid in pairs(members) do
    if mid ~= id then send(mid, 'LL_cfg', {cfg = d.cfg}) end
  end
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
  removeAndList(tonumber(id), true)
end

MP.RegisterEvent('LL_join', 'LivraisonLibre_join')
MP.RegisterEvent('LL_leave', 'LivraisonLibre_leave')
MP.RegisterEvent('LL_propose', 'LivraisonLibre_propose')
MP.RegisterEvent('LL_done', 'LivraisonLibre_done')
MP.RegisterEvent('LL_players', 'LivraisonLibre_players')
MP.RegisterEvent('LL_invite', 'LivraisonLibre_invite')
MP.RegisterEvent('LL_cfg', 'LivraisonLibre_cfg')
MP.RegisterEvent('onPlayerJoin', 'LivraisonLibre_playerJoin')
MP.RegisterEvent('onPlayerDisconnect', 'LivraisonLibre_disconnect')
print('[LivraisonLibre] plugin serveur chargé (messages v' .. PROTO .. ')')
