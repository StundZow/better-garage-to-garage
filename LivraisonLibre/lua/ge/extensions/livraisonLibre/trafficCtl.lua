-- Livraison Libre - pilotage du trafic, des voitures garées et de la police (gameplay_traffic / parking / police)

local M = {}

local owned = false      -- le trafic actuel a été créé par le mod
local ready = true
local POLICE_PROVIDER = 'livraisonLibrePolice'

-- Code exécuté dans les véhicules de trafic (Lua véhicule).
-- PNJ qui ignorent les sirènes : l'IA se range dès qu'elle voit un "lightbar" actif dans mapmgr ;
-- on retire cet état des objets qu'elle lit, sans rien changer d'autre.
local IGNORE_SIRENS_ON = [[
if mapmgr and mapmgr.getObjects and not mapmgr._llOrigGetObjects then
  local orig = mapmgr.getObjects
  mapmgr._llOrigGetObjects = orig
  mapmgr.getObjects = function()
    local objs = orig()
    for _, o in pairs(objs) do
      local st = o.states
      if st and st.lightbar then st.lightbar = nil end
    end
    return objs
  end
end]]
local IGNORE_SIRENS_OFF = [[if mapmgr and mapmgr._llOrigGetObjects then mapmgr.getObjects = mapmgr._llOrigGetObjects; mapmgr._llOrigGetObjects = nil end]]
-- Police sans gyrophares ni sirènes (solution de secours)
local NO_SIREN_ON = [[
if electrics and electrics.set_lightbar_signal and not electrics._llOrigLightbar then
  local orig = electrics.set_lightbar_signal
  electrics._llOrigLightbar = orig
  electrics.set_lightbar_signal = function() orig(0) end
  orig(0)
end]]
local NO_SIREN_OFF = [[if electrics and electrics._llOrigLightbar then electrics.set_lightbar_signal = electrics._llOrigLightbar; electrics._llOrigLightbar = nil end]]
local patched = {}       -- vehId -> {ignore = bool, noSiren = bool}

local function ext(name)
  if not _G[name] and extensions and extensions.load then pcall(extensions.load, name) end
  return _G[name]
end

function M.levelSupportsTraffic(levelName)
  local levels = ext('core_levels')
  if not levels or not levels.getLevelByName or not levelName then return true end
  local ok, info = pcall(levels.getLevelByName, levelName)
  if ok and type(info) == 'table' and info.supportsTraffic == false then return false end
  return true
end

-- Applique les réglages. Renvoie 'skipped' | 'done' | 'waiting' | 'error', message éventuel.
function M.apply(t, levelName)
  if not t or t.mode == 'keep' then return 'skipped' end
  local gt, gp = ext('gameplay_traffic'), ext('gameplay_parking')
  if not gt then return 'error', 'Système de trafic indisponible.' end

  if t.mode == 'off' then
    pcall(gt.deleteVehicles)
    if gp and gp.deleteVehicles then pcall(gp.deleteVehicles) end
    owned = false
    ready = true
    return 'done'
  end

  if not M.levelSupportsTraffic(levelName) then
    return 'skipped', "Cette map ne gère pas le trafic : livraisons sans trafic."
  end

  local usePolice = t.police ~= 'off'
  -- nombre de policiers selon le ratio choisi (au lieu du quart fixe du jeu)
  local policeCount = 0
  if usePolice then
    policeCount = math.max(1, math.min(t.amount, math.floor(t.amount * (t.policeRatio or 0.25) + 0.5)))
  end
  local providerSet = false
  if policeCount > 0 and gt.registerSpecialVehicleProvider then
    providerSet = pcall(gt.registerSpecialVehicleProvider, {
      name = POLICE_PROVIDER,
      priority = 11,
      minTotalAmount = 1,
      guaranteed = policeCount, -- dépasse la limite de 40 % de véhicules spéciaux du jeu si besoin
      getDesiredCount = function(total, options) return (options and options.llPoliceCount) or 0 end,
      buildGroup = function(count)
        local tu = _G.gameplay_traffic_trafficUtils
        local group = (tu and tu.createPoliceGroup) and tu.createPoliceGroup(count) or {}
        if not group[1] then
          for i = 1, count do group[i] = {model = 'fullsize', config = 'police'} end
        end
        return group
      end,
    })
  end
  ready = false
  local ok, tSetup, pSetup = pcall(gt.setupTrafficHelper, t.amount, {police = false, llPoliceCount = providerSet and policeCount or 0}, t.parked, {})
  if providerSet and gt.unregisterSpecialVehicleProvider then pcall(gt.unregisterSpecialVehicleProvider, POLICE_PROVIDER) end
  if not ok then
    ready = true
    return 'error', 'Lancement du trafic impossible : ' .. tostring(tSetup)
  end
  pcall(gt.setTrafficVars, {aiMode = 'traffic', enableRandomEvents = usePolice})
  local police = ext('gameplay_police')
  if police and police.setPursuitVars then pcall(police.setPursuitVars, {strictness = t.strictness}) end
  owned = true
  if tSetup or pSetup then return 'waiting' end
  ready = true
  return 'done'
end

function M.onReady() ready = true end
function M.isReady() return ready end
function M.isOwned() return owned end

-- Supprime tout le trafic et les voitures garées (créés par le mod ou non)
function M.removeAll()
  local gt, gp = ext('gameplay_traffic'), ext('gameplay_parking')
  if gt and gt.deleteVehicles then pcall(gt.deleteVehicles) end
  if gp and gp.deleteVehicles then pcall(gp.deleteVehicles) end
  owned = false
  ready = true
end

-- Supprime le trafic seulement s'il a été créé par le mod
function M.removeOwned()
  if owned then M.removeAll() end
end

-- Après un téléport : rapproche le trafic et les voitures garées de la nouvelle position
function M.scatter()
  local gt, gp = _G.gameplay_traffic, _G.gameplay_parking
  if gt and gt.getState and gt.getState() == 'on' and gt.scatterTraffic then pcall(gt.scatterTraffic) end
  if gp and gp.getState and gp.getState() and gp.scatterParkedCars then pcall(gp.scatterParkedCars) end
end

function M.status()
  local gt, gp, police = _G.gameplay_traffic, _G.gameplay_parking, _G.gameplay_police
  local st = {state = 'off', amount = 0, parked = 0, police = 0}
  if gt then
    local ok, s = pcall(gt.getState)
    if ok and s then st.state = s end
    local ok2, n = pcall(gt.getTrafficAmount)
    if ok2 and type(n) == 'number' then st.amount = n end
  end
  if gp and gp.getParkedCarsAmount then
    local ok, n = pcall(gp.getParkedCarsAmount)
    if ok and type(n) == 'number' then st.parked = n end
  end
  if police and police.getPoliceVehicles then
    local ok, list = pcall(police.getPoliceVehicles)
    if ok and type(list) == 'table' then
      for _ in pairs(list) do st.police = st.police + 1 end
    end
  end
  st.active = (st.state == 'on' and st.amount > 0) or st.parked > 0
  return st
end

-- Applique (ou retire) les correctifs de sirènes sur les véhicules de trafic.
-- ignore : les PNJ ne se rangent plus pour les sirènes ; noSiren : la police n'allume plus ses gyrophares.
function M.updateSirenPatches(ignore, noSiren)
  local gt = _G.gameplay_traffic
  if not gt or not gt.getTrafficData then return end
  local ok, data = pcall(gt.getTrafficData)
  if not ok or type(data) ~= 'table' then return end
  for id, veh in pairs(data) do
    local obj = getObjectByID(id)
    if obj and veh.isAi then
      local p = patched[id] or {}
      local isPolice = veh.roleName == 'police'
      local wantIgnore = ignore and true or false
      local wantNoSiren = (noSiren and isPolice) and true or false
      if wantIgnore then pcall(obj.queueLuaCommand, obj, IGNORE_SIRENS_ON)
      elseif p.ignore then pcall(obj.queueLuaCommand, obj, IGNORE_SIRENS_OFF) end
      if wantNoSiren then pcall(obj.queueLuaCommand, obj, NO_SIREN_ON)
      elseif p.noSiren then pcall(obj.queueLuaCommand, obj, NO_SIREN_OFF) end
      patched[id] = {ignore = wantIgnore, noSiren = wantNoSiren}
    end
  end
end

function M.clearSirenPatches()
  for id, p in pairs(patched) do
    local obj = getObjectByID(id)
    if obj then
      if p.ignore then pcall(obj.queueLuaCommand, obj, IGNORE_SIRENS_OFF) end
      if p.noSiren then pcall(obj.queueLuaCommand, obj, NO_SIREN_OFF) end
    end
  end
  patched = {}
end

-- 0 à 5 étoiles selon le score de poursuite du jeu (qui n'a que 3 niveaux)
M.STAR_SCORES = {100, 300, 500, 1200, 2000}
function M.starsFor(pursuit)
  if type(pursuit) ~= 'table' or (tonumber(pursuit.mode) or 0) <= 0 then return 0 end
  local score, stars = tonumber(pursuit.score) or 0, 1
  for i = 2, 5 do
    if score >= M.STAR_SCORES[i] then stars = i end
  end
  if pursuit.mode >= 3 then stars = math.max(stars, 5) elseif pursuit.mode >= 2 then stars = math.max(stars, 3) end
  return stars
end

function M.pursuitData(vehId)
  local police = _G.gameplay_police
  if not police or not police.getPursuitData or not vehId then return nil end
  local ok, data = pcall(police.getPursuitData, vehId)
  if ok and type(data) == 'table' then return data end
  return nil
end

-- niveau de départ en étoiles (1 à 5) -> niveau de poursuite du jeu (1 à 3)
function M.modeForStars(stars)
  stars = stars or 1
  if stars >= 5 then return 3 elseif stars >= 3 then return 2 end
  return 1
end

-- Près de l'arrivée : fin de la poursuite et voitures de police proches envoyées plus loin,
-- pour pouvoir se garer tranquillement. Renvoie le nombre de voitures déplacées.
function M.clearPoliceNear(playerId, pos, radius)
  local gt, police = _G.gameplay_traffic, _G.gameplay_police
  if not gt or not gt.getTrafficData then return 0 end
  if playerId and police and police.setPursuitMode and M.pursuitMode(playerId) > 0 then
    pcall(police.setPursuitMode, 0, playerId)
  end
  local ok, data = pcall(gt.getTrafficData)
  if not ok or type(data) ~= 'table' then return 0 end
  local moved, r2 = 0, (radius or 300) ^ 2
  for id, veh in pairs(data) do
    if veh.isAi and veh.roleName == 'police' and id ~= playerId then
      local obj = getObjectByID(id)
      if obj then
        local p = obj:getPosition()
        local dx, dy = p.x - pos.x, p.y - pos.y
        if dx * dx + dy * dy < r2 and gt.forceTeleport then
          if pcall(gt.forceTeleport, id, vec3(pos.x, pos.y, pos.z), nil, 400, 900) then moved = moved + 1 end
        end
      end
    end
  end
  return moved
end

function M.pursuitMode(vehId)
  local police = _G.gameplay_police
  if not police or not police.getPursuitData or not vehId then return 0 end
  local ok, data = pcall(police.getPursuitData, vehId)
  if ok and type(data) == 'table' and type(data.mode) == 'number' then return data.mode end
  return 0
end

function M.resetPursuit(vehId)
  local police = _G.gameplay_police
  if police and police.setPursuitMode and vehId then pcall(police.setPursuitMode, 0, vehId) end
end

-- Mode "recherché" : la police prend le joueur en chasse dès qu'elle le repère
function M.setWanted(vehId, level)
  local police = ext('gameplay_police')
  if not police or not police.setupPursuitGameplay or not vehId then return false end
  local ok, res = pcall(police.setupPursuitGameplay, vehId, nil, {pursuitMode = M.modeForStars(level)})
  return ok and res == true
end

return M
