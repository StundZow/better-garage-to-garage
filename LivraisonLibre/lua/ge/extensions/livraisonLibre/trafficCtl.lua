-- Livraison Libre - pilotage du trafic, des voitures garées et de la police (gameplay_traffic / parking / police)

local M = {}

local owned = false      -- le trafic actuel a été créé par le mod
local ready = true
local pendingRemoval = false -- arrêt demandé pendant que le trafic du mod se charge encore
local savedVars = nil    -- réglages de la police du jeu avant les livraisons (remis à l'arrêt)
local VAR_KEYS = {'strictness', 'suspectFrequency', 'roadblockFrequency', 'evadeTime', 'evadeRadius'}

-- garde les réglages de la police du jeu avant le premier changement fait par le mod
local function saveVars()
  if savedVars then return end
  local police = _G.gameplay_police
  if not police or not police.getPursuitVars then return end
  local ok, v = pcall(police.getPursuitVars)
  if ok and type(v) == 'table' then
    savedVars = {}
    for _, k in ipairs(VAR_KEYS) do savedVars[k] = v[k] end
  end
end
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

local function isPolice(veh)
  return type(veh) == 'table' and ((veh.role and veh.role.name) or veh.roleName) == 'police'
end

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
        if t.progressive ~= false and count >= 2 then group = M.addHeavyPolice(group, 0.34) end
        return group
      end,
    })
  end
  ready = false
  pendingRemoval = false
  local ok, tSetup, pSetup = pcall(gt.setupTrafficHelper, t.amount, {police = false, llPoliceCount = providerSet and policeCount or 0}, t.parked, {})
  if providerSet and gt.unregisterSpecialVehicleProvider then pcall(gt.unregisterSpecialVehicleProvider, POLICE_PROVIDER) end
  if not ok then
    ready = true
    return 'error', 'Lancement du trafic impossible : ' .. tostring(tSetup)
  end
  pcall(gt.setTrafficVars, {aiMode = 'traffic', enableRandomEvents = usePolice})
  local police = ext('gameplay_police')
  if police and police.setPursuitVars then
    saveVars()
    pcall(police.setPursuitVars, {strictness = t.strictness, suspectFrequency = (t.npcChases ~= false) and 0.5 or 0})
  end
  owned = true
  if tSetup or pSetup then return 'waiting' end
  ready = true
  return 'done'
end

function M.onReady()
  ready = true
  -- arrêt demandé pendant le chargement : le trafic n'existait pas encore, on le retire maintenant
  if pendingRemoval then
    pendingRemoval = false
    M.removeAll()
  end
end
function M.isReady() return ready end
function M.isOwned() return owned end

-- Supprime tout le trafic et les voitures garées (créés par le mod ou non)
function M.removeAll()
  if owned and not ready then
    -- le jeu crée encore le trafic du mod (un véhicule par image) : retiré dès qu'il est prêt
    pendingRemoval = true
    return
  end
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
      local policeVeh = isPolice(veh)
      local wantIgnore = ignore and true or false
      local wantNoSiren = (noSiren and policeVeh) and true or false
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
    if veh.isAi and isPolice(veh) and id ~= playerId then
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

-- Places du système de parking du jeu qui chevauchent la zone de livraison : marquées occupées pour
-- qu'aucune voiture garée n'y soit placée (le jeu peut utiliser sa propre copie des places, différente
-- de celle lue par le mod). Renvoie la liste des places marquées.
function M.reserveParkingNear(x, y, z, radius, val)
  local out = {}
  local gp = _G.gameplay_parking
  if not gp or not gp.getParkingSpots then return out end
  local ok, list = pcall(gp.getParkingSpots)
  if not ok or type(list) ~= 'table' or type(list.sorted) ~= 'table' then return out end
  local r2 = radius * radius
  for _, ps in ipairs(list.sorted) do
    local p = type(ps) == 'table' and ps.pos
    if p and ps.vehicle == nil and not ps.missing then
      local dx, dy, dz = p.x - x, p.y - y, p.z - z
      if dx * dx + dy * dy <= r2 and math.abs(dz) < 4 then
        ps.vehicle = val
        out[#out + 1] = ps
      end
    end
  end
  return out
end

-- Déplace ailleurs les voitures garées (et les PNJ arrêtés) posés sur la zone de livraison.
-- ignore : {vehId = true} (véhicule de livraison, véhicule du joueur). Renvoie le nombre de véhicules déplacés.
function M.clearZone(zone, ignore)
  if not zone or not be then return 0 end
  local gp, gt = _G.gameplay_parking, _G.gameplay_traffic
  local parked, traffic
  if gp and gp.getParkedCarsData then
    local ok, d = pcall(gp.getParkedCarsData)
    if ok and type(d) == 'table' then parked = d end
  end
  if gt and gt.getTrafficData then
    local ok, d = pcall(gt.getTrafficData)
    if ok and type(d) == 'table' then traffic = d end
  end
  if not parked and not traffic then return 0 end
  local r = math.sqrt((zone.w * 0.5) ^ 2 + (zone.l * 0.5) ^ 2) + 1.5
  local pos = vec3(zone.x, zone.y, zone.z)
  local moved = 0
  for i = 0, be:getObjectCount() - 1 do
    local obj = be:getObject(i)
    local id = obj and obj:getID()
    if id and not (ignore and ignore[id]) then
      local x, y, z = be:getObjectOOBBCenterXYZ(id)
      local dx, dy, dz = x - zone.x, y - zone.y, z - zone.z
      if dx * dx + dy * dy < r * r and math.abs(dz) < 4 then
        if parked and parked[id] and gp.forceTeleport then
          if pcall(gp.forceTeleport, id, pos, 150, 800) then moved = moved + 1 end
        elseif traffic and traffic[id] and traffic[id].isAi and (tonumber(traffic[id].speed) or 0) < 1 and gt.forceTeleport then
          if pcall(gt.forceTeleport, id, pos, nil, 300, 900) then moved = moved + 1 end
        end
      end
    end
  end
  return moved
end

-- À l'approche de la place (joueur à moins de 50 m) : tout le trafic autour de la place est envoyé plus loin
-- (voitures qui roulent, arrêtées ou garées dessus), sauf la police lancée à la poursuite du joueur.
function M.clearAround(zone, radius, playerId, ignore)
  local gt = _G.gameplay_traffic
  local moved = 0
  if gt and gt.getTrafficData and gt.forceTeleport and zone then
    local ok, data = pcall(gt.getTrafficData)
    if ok and type(data) == 'table' then
      local r2 = radius * radius
      local pos = vec3(zone.x, zone.y, zone.z)
      for id, veh in pairs(data) do
        local role = veh.role
        local chasing = role and role.flags and role.flags.pursuit and role.targetId == playerId
        if veh.isAi and not chasing and not (ignore and ignore[id]) then
          local obj = getObjectByID(id)
          if obj then
            local p = obj:getPosition()
            local dx, dy = p.x - zone.x, p.y - zone.y
            if dx * dx + dy * dy < r2 and math.abs(p.z - zone.z) < 8 then
              if pcall(gt.forceTeleport, id, pos, nil, 400, 900) then moved = moved + 1 end
            end
          end
        end
      end
    end
  end
  return moved + M.clearZone(zone, ignore) -- et les voitures garées sur la place
end

-- Difficulté progressive selon les étoiles. Le jeu a 3 comportements : niveau 1 = la police suit sans
-- foncer (1-2 étoiles), niveau 2 = poursuite agressive (3-4 étoiles), niveau 3 = barrages (5 étoiles).
-- On ajuste en plus, étoile par étoile : agressivité de l'IA, fréquence des barrages, difficulté pour
-- semer la police et renforts amenés près du joueur.
M.STAR_TUNING = {
  {aggression = 0.3,  roadblock = 0,   evadeTime = 25, evadeRadius = 70,  reinforce = 0},
  {aggression = 0.5,  roadblock = 0,   evadeTime = 35, evadeRadius = 80,  reinforce = 0},
  {aggression = 0.9,  roadblock = 0.3, evadeTime = 45, evadeRadius = 90,  reinforce = 0},
  {aggression = 1.1,  roadblock = 0.6, evadeTime = 60, evadeRadius = 110, reinforce = 1},
  {aggression = 1.25, roadblock = 1.0, evadeTime = 80, evadeRadius = 130, reinforce = 2},
}
local DEFAULT_PURSUIT_VARS = {roadblockFrequency = 0.5, evadeTime = 45, evadeRadius = 80}
-- voitures de police lourdes (contenu officiel) mêlées aux patrouilles créées par le mod
M.HEAVY_POLICE = {
  {model = 'roamer', config = 'police'},
  {model = 'midtruck', config = '4x4_police_petrol'},
  {model = 'bastion', config = 'police_v8_awd_A'},
  {model = 'md_series', config = 'md_60_armored_police'},
}
local HEAVY_MODELS = {roamer = true, midtruck = true, bastion = true, md_series = true}
local tune = {stars = -1, aggr = {}, reinforceTimer = 5}

-- Remplace une partie d'un groupe de police par des véhicules lourds (si le jeu les a).
function M.addHeavyPolice(group, share)
  if type(group) ~= 'table' or not group[1] then return group end
  local cv = _G.core_vehicles
  local avail = {}
  for _, h in ipairs(M.HEAVY_POLICE) do
    local ok, m = true, nil
    if cv and cv.getModel then ok, m = pcall(cv.getModel, h.model) end
    if not cv or not cv.getModel or (ok and m and m.model) then avail[#avail + 1] = h end
  end
  if not avail[1] then return group end
  local n = math.floor(#group * (share or 0.34) + 0.5)
  for i = 1, n do
    local h = avail[((i - 1) % #avail) + 1]
    local slot = #group - i + 1
    if slot >= 1 then group[slot] = {model = h.model, config = h.config} end
  end
  return group
end

-- réglages de poursuite hors difficulté progressive : ceux du jeu avant les livraisons
local function baseVars()
  if not savedVars then return DEFAULT_PURSUIT_VARS end
  return {
    roadblockFrequency = savedVars.roadblockFrequency or DEFAULT_PURSUIT_VARS.roadblockFrequency,
    evadeTime = savedVars.evadeTime or DEFAULT_PURSUIT_VARS.evadeTime,
    evadeRadius = savedVars.evadeRadius or DEFAULT_PURSUIT_VARS.evadeRadius,
  }
end

function M.resetTuning()
  if tune.stars ~= -1 then
    local police = _G.gameplay_police
    if police and police.setPursuitVars then pcall(police.setPursuitVars, baseVars()) end
  end
  tune = {stars = -1, aggr = {}, reinforceTimer = 5}
end

-- À appeler régulièrement pendant une livraison (playerId : véhicule poursuivi, stars : 0 à 5).
function M.tunePolice(playerId, stars, dt)
  local police, gt = _G.gameplay_police, _G.gameplay_traffic
  if not police or not gt or not gt.getTrafficData or not playerId then return end
  stars = stars or 0
  local t = M.STAR_TUNING[stars]
  if stars ~= tune.stars then
    tune.stars = stars
    tune.aggr = {}
    if police.setPursuitVars then
      saveVars()
      pcall(police.setPursuitVars, t and {roadblockFrequency = t.roadblock, evadeTime = t.evadeTime, evadeRadius = t.evadeRadius} or baseVars())
    end
  end
  if not t then return end
  local ok, data = pcall(gt.getTrafficData)
  if not ok or type(data) ~= 'table' then return end

  -- agressivité des voitures qui poursuivent le joueur
  local idle = {}
  for id, veh in pairs(data) do
    if veh.isAi and isPolice(veh) and id ~= playerId then
      local chasing = veh.role and veh.role.flags and veh.role.flags.pursuit and veh.role.targetId == playerId
      if chasing then
        -- le jeu remet sa propre agressivité à chaque changement d'action (poursuite, esquive, arrêt...)
        local key = t.aggression .. '|' .. tostring(veh.role.actionName)
        if tune.aggr[id] ~= key then
          local obj = getObjectByID(id)
          if obj then pcall(obj.queueLuaCommand, obj, 'ai.setAggression(' .. t.aggression .. ')') end
          tune.aggr[id] = key
        end
      elseif not (veh.role and veh.role.flags and (veh.role.flags.roadblock or veh.role.flags.cooldown)) then
        idle[#idle + 1] = {id = id, veh = veh}
      end
    end
  end

  -- renforts (4-5 étoiles) : des voitures de police éloignées sont amenées près du joueur, hors de vue
  if t.reinforce > 0 and gt.forceTeleport and idle[1] then
    tune.reinforceTimer = tune.reinforceTimer - (dt or 0)
    if tune.reinforceTimer <= 0 then
      tune.reinforceTimer = 20
      local pobj = getObjectByID(playerId)
      if pobj then
        local ppos, pdir = pobj:getPosition(), pobj:getDirectionVector()
        -- les plus lointaines d'abord, les lourdes en priorité à 5 étoiles
        for _, it in ipairs(idle) do
          local o = getObjectByID(it.id)
          it.d = o and (o:getPosition() - ppos):length() or 0
          it.heavy = HEAVY_MODELS[tostring(it.veh.model or '')] and 1 or 0
        end
        table.sort(idle, function(a, b)
          if stars >= 5 and a.heavy ~= b.heavy then return a.heavy > b.heavy end
          return a.d > b.d
        end)
        local sent = 0
        for _, it in ipairs(idle) do
          if sent >= t.reinforce then break end
          if it.d > 450 then
            if pcall(gt.forceTeleport, it.id, ppos, pdir, 180, 400) then sent = sent + 1 end
          end
        end
      end
    end
  end
end

-- Choc contre une voiture de police alors qu'on n'est pas recherché : 1 étoile, à coup sûr.
-- (Le jeu ne compte ce choc que si la police t'avait déjà repéré, et pas pendant certaines de ses
-- actions.) On reprend son critère de responsabilité : c'est toi qui avançais vers elle.
-- Renvoie true si une poursuite vient d'être lancée.
function M.checkPoliceHit(playerId)
  local gt, police = _G.gameplay_traffic, _G.gameplay_police
  if not playerId or not gt or not gt.getTrafficData or not police or not police.setPursuitMode then return false end
  local ok, data = pcall(gt.getTrafficData)
  if not ok or type(data) ~= 'table' then return false end
  local me = data[playerId]
  if type(me) ~= 'table' or type(me.collisions) ~= 'table' or type(me.pursuit) ~= 'table' then return false end
  if (tonumber(me.pursuit.mode) or 0) ~= 0 then return false end -- déjà recherché (ou en cours d'arrestation)
  for id, coll in pairs(me.collisions) do
    if type(coll) == 'table' and coll.inArea and not coll.llPoliceHit and isPolice(data[id])
      and (tonumber(coll.speed) or 0) >= 1 and (tonumber(coll.dot) or 0) >= 0.2 then
      coll.llPoliceHit = true
      coll.offense = true -- le jeu n'ajoute pas en plus sa propre pénalité pour ce même choc
      if pcall(police.setPursuitMode, 1, playerId, {id}) then return true end
    end
  end
  return false
end

-- Poursuites de PNJ : de temps en temps, le jeu désigne une voiture du trafic comme suspecte et la
-- police la prend en chasse, sirènes allumées (événement aléatoire du trafic). false = jamais.
function M.setNpcChases(on)
  local police = _G.gameplay_police
  if police and police.setPursuitVars then
    saveVars()
    pcall(police.setPursuitVars, {suspectFrequency = on and 0.5 or 0})
  end
end

-- Police réglée en pleine livraison : 'off' (la police ne réagit plus à rien), 'patrol' (seulement
-- sur infraction), 'wanted' (recherché tout de suite au nombre d'étoiles choisi).
-- strictness : sévérité normale à remettre ; renvoie false si la recherche n'a pas pu démarrer.
local savedStrictness = nil
function M.setPoliceMode(vehId, mode, level, strictness)
  local police = _G.gameplay_police
  if not police or not police.setPursuitVars then return false end
  saveVars()
  if mode == 'off' then
    if savedStrictness == nil then
      local ok, vars = pcall(police.getPursuitVars or function() end)
      savedStrictness = (ok and type(vars) == 'table' and tonumber(vars.strictness)) or strictness or 0.5
    end
    pcall(police.setPursuitVars, {strictness = 0}) -- plus aucune infraction relevée, plus de poursuite
    M.resetPursuit(vehId)
    return true
  end
  -- police remise en route : sévérité d'avant la coupure, sinon celle choisie (nil : inchangée)
  local s = savedStrictness or strictness
  savedStrictness = nil
  if s then pcall(police.setPursuitVars, {strictness = s}) end
  M.resetPursuit(vehId)
  if mode == 'wanted' then return M.setWanted(vehId, level) end
  return true
end

-- Fin des livraisons : réglages de la police du jeu tels qu'avant (sévérité, poursuites de PNJ...)
function M.restorePolice()
  local police = _G.gameplay_police
  if savedStrictness ~= nil then
    if police and police.setPursuitVars then pcall(police.setPursuitVars, {strictness = savedStrictness}) end
    savedStrictness = nil
  end
  if savedVars then
    if police and police.setPursuitVars then pcall(police.setPursuitVars, savedVars) end
    savedVars = nil
  end
end

-- Map quittée : le jeu remet lui-même ses réglages, rien à remettre ni à retirer plus tard
function M.forget()
  savedVars, savedStrictness, pendingRemoval = nil, nil, false
  owned, ready = false, true
end

function M.pursuitMode(vehId)
  local police = _G.gameplay_police
  if not police or not police.getPursuitData or not vehId then return 0 end
  local ok, data = pcall(police.getPursuitData, vehId)
  if ok and type(data) == 'table' and type(data.mode) == 'number' then return data.mode end
  return 0
end

-- recherché (rôle de suspect donné par le jeu) ou déjà poursuivi
function M.isWanted(vehId)
  if M.pursuitMode(vehId) > 0 then return true end
  local gt = _G.gameplay_traffic
  if not gt or not gt.getTrafficData or not vehId then return false end
  local ok, data = pcall(gt.getTrafficData)
  local v = ok and type(data) == 'table' and data[vehId]
  return type(v) == 'table' and ((v.role and v.role.name) or v.roleName) == 'suspect'
end

function M.resetPursuit(vehId)
  local police = _G.gameplay_police
  if police and police.setPursuitMode and vehId then pcall(police.setPursuitMode, 0, vehId) end
end

-- Mode "recherché" : la police prend le joueur en chasse dès qu'elle le repère
function M.setWanted(vehId, level)
  local police = ext('gameplay_police')
  if not police or not police.setupPursuitGameplay or not vehId then return false end
  -- déjà poursuivi : on ne relance pas (le jeu arrêterait la poursuite en cours)
  if M.pursuitMode(vehId) > 0 then return true end
  local ok, res = pcall(police.setupPursuitGameplay, vehId, nil, {pursuitMode = M.modeForStars(level)})
  return ok and res == true
end

return M
