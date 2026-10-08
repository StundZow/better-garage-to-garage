-- Mock minimal de l'API GE de BeamNG utilisée par livraisonLibre.lua
local env = {
  events = {}, eventCount = {}, files = {}, logs = {}, messages = {},
  decals = 0, beams = 0, vluaCmds = {}, paths = {}, fades = {}, deleted = {},
  level = 'testcity', groundZ = 10, frame = 0,
}

-- vec3 / quat ---------------------------------------------------------------
local vmt = {}
vmt.__index = vmt
function vec3(x, y, z)
  if type(x) == 'table' then return setmetatable({x = x.x or x[1] or 0, y = x.y or x[2] or 0, z = x.z or x[3] or 0}, vmt) end
  return setmetatable({x = x or 0, y = y or 0, z = z or 0}, vmt)
end
vmt.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vmt.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
vmt.__mul = function(a, b)
  if type(a) == 'number' then return vec3(b.x * a, b.y * a, b.z * a) end
  return vec3(a.x * b, a.y * b, a.z * b)
end
vmt.__unm = function(a) return vec3(-a.x, -a.y, -a.z) end
function vmt:set(x, y, z)
  if type(x) == 'table' then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x, y, z end
end
function vmt:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
function vmt:normalized() local l = self:length(); if l == 0 then return vec3(0, 0, 0) end return vec3(self.x / l, self.y / l, self.z / l) end
function vmt:dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function vmt:cross(b) return vec3(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end
function vmt:distance(b) return (self - b):length() end

local qmt = {}
qmt.__index = qmt
function quatFromDir(dir, up)
  local d = vec3(dir):normalized()
  return setmetatable({dir = d, up = vec3(up or vec3(0, 0, 1)):normalized()}, qmt)
end
qmt.__mul = function(q, v)
  if getmetatable(v) == qmt then return v end
  local right = q.dir:cross(q.up):normalized()
  return right * v.x + q.dir * v.y + q.up * v.z
end
function quat(x, y, z, w) return quatFromDir(vec3(0, 1, 0)) end

function ColorF(r, g, b, a) return {r = r, g = g, b = b, a = a} end

-- journal, ui ----------------------------------------------------------------
function log(level, tag, msg)
  table.insert(env.logs, {level = level, tag = tag, msg = msg})
  if level == 'E' or level == 'W' then print('  [' .. level .. '] ' .. tostring(tag) .. ': ' .. tostring(msg)) end
end
-- vérifie qu'une valeur Lua est encodable en JSON sans surprise
local function checkJson(v, path, seen)
  local t = type(v)
  if t == 'number' then
    assert(v == v and v ~= math.huge and v ~= -math.huge, 'nombre non fini dans ' .. path)
  elseif t == 'table' then
    seen = seen or {}
    assert(not seen[v], 'table cyclique dans ' .. path)
    seen[v] = true
    local nArr, nKey = 0, 0
    for k, val in pairs(v) do
      if type(k) == 'number' then nArr = nArr + 1 elseif type(k) == 'string' then nKey = nKey + 1
      else error('clé non encodable dans ' .. path) end
      checkJson(val, path .. '.' .. tostring(k), seen)
    end
    assert(nArr == 0 or nKey == 0, 'table mixte tableau/objet dans ' .. path)
    seen[v] = nil
  elseif t == 'function' or t == 'userdata' or t == 'thread' then
    error('valeur non encodable (' .. t .. ') dans ' .. path)
  end
end
env.checkJson = checkJson

guihooks = {
  trigger = function(name, data)
    checkJson(data, name)
    env.events[name] = data
    env.eventCount[name] = (env.eventCount[name] or 0) + 1
  end,
  message = function(msg) table.insert(env.messages, msg) end,
}
function ui_message(msg, ttl, cat, icon) table.insert(env.messages, msg) end

-- fichiers -------------------------------------------------------------------
local function deepcopy(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = deepcopy(v) end
  return o
end
function jsonWriteFile(path, data, pretty) checkJson(data, path); env.files[path] = deepcopy(data); return true end
function jsonReadFile(path) return deepcopy(env.files[path]) end
FS = {
  directoryExists = function(self, p) return true end,
  directoryCreate = function(self, p) return true end,
  findFiles = function(self, dir, pattern)
    return {
      dir .. 'city.sites.json',
      dir .. 'facilities/delivery/residential.sites.json',
      dir .. 'driftSpots/test/bounds.sites.json',
    }
  end,
}

-- véhicules ------------------------------------------------------------------
env.vehicles = {}
env.playerId = -1
local nextId = 1000
local SIZES = {}
env.SIZES = SIZES

local function newVeh(model, config, pos, rot)
  local s = SIZES[model] or {2.0, 4.8}
  local v = {id = nextId, model = model, config = config, pos = vec3(pos), dir = vec3(0, 1, 0), up = vec3(0, 0, 1),
    vel = vec3(0, 0, 0), w = s[1], l = s[2], h = 1.5, parkbrake = 0}
  if rot and rot.dir then v.dir = vec3(rot.dir) end
  nextId = nextId + 1
  function v:getID() return self.id end
  function v:getId() return self.id end
  function v:getPosition() return vec3(self.pos) end
  function v:getVelocityXYZ() return self.vel.x, self.vel.y, self.vel.z end
  function v:getDirectionVector() return vec3(self.dir) end
  function v:getDirectionVectorUp() return vec3(self.up) end
  function v:queueLuaCommand(cmd) table.insert(env.vluaCmds, {veh = self, cmd = cmd}) end
  function v:delete()
    env.vehicles[self.id] = nil
    table.insert(env.deleted, self.id)
    if env.playerId == self.id then env.playerId = -1 end
    if livraisonLibre and livraisonLibre.onVehicleDestroyed then livraisonLibre.onVehicleDestroyed(self.id) end
  end
  v.initialNodePosBB = {getExtents = function() return vec3(v.w, v.l, v.h) end}
  v.JBeam = model
  v.partConfig = config
  env.vehicles[v.id] = v
  return v
end
env.newVeh = newVeh

local function sortedIds()
  local ids = {}
  for id in pairs(env.vehicles) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

be = {}
function be:getObjectCount() return #sortedIds() end
function be:getObject(i) return env.vehicles[sortedIds()[i + 1]] end
function be:getPlayerVehicleID(p) return env.playerId end
function be:getObjectOOBBCenterXYZ(id)
  local v = env.vehicles[id]
  return v.pos.x, v.pos.y, v.pos.z + v.h / 2
end
function be:getObjectOOBBHalfAxisXYZ(id, i)
  local v = env.vehicles[id]
  local right = v.dir:cross(v.up):normalized()
  local a
  if i == 0 then a = right * (v.w / 2) elseif i == 1 then a = v.dir * (v.l / 2) else a = v.up * (v.h / 2) end
  return a.x, a.y, a.z
end
function be:getSurfaceHeightBelow(p) return env.groundZ end
function be:enterVehicle(p, veh) env.playerId = veh:getID() end
function getPlayerVehicle(p) return env.vehicles[env.playerId] end
function getObjectByID(id) return env.vehicles[id] end

-- VM "vehicle lua" persistante par véhicule : electrics, mapmgr, obj
local function vmFor(veh)
  if not veh.vm then
    local vm = {tostring = tostring, pairs = pairs}
    vm.electrics = {values = {}, set_lightbar_signal = function(x) veh.lightbar = x end}
    vm.mapmgr = {objects = {}}
    vm.mapmgr.getObjects = function()
      -- un véhicule de police voisin avec sirène allumée
      vm.mapmgr.objects = {[1] = {states = {lightbar = 2}}, [2] = {states = {}}}
      return vm.mapmgr.objects
    end
    vm.obj = {queueGameEngineLua = function(self, s) assert(load(s, 'ge', 't', _G))() end,
      sendForceFeedback = function(self, id, f) veh.ffbForce = f end}
    vm.pcall = pcall
    vm.ai = {setAggression = function(x) veh.aiAggression = x end}
    -- retour de force (lua/vehicle/hydros.lua)
    vm.hydros = {enableFFB = true, getFFBID = function() return 0 end,
      getForceFeedbackFunction = function() return function(o, id, f) veh.ffbForce = f end end}
    veh.vm = vm
  end
  veh.vm.electrics.values.parkingbrake = veh.parkbrake
  return veh.vm
end
env.vmFor = vmFor

-- exécute les commandes "vehicle lua" en attente
function env.flushVlua()
  local cmds = env.vluaCmds
  env.vluaCmds = {}
  env.vluaLog = env.vluaLog or {}
  for _, c in ipairs(cmds) do
    table.insert(env.vluaLog, c)
    local fn, err = load(c.cmd, 'vlua', 't', vmFor(c.veh))
    assert(fn, 'vlua syntax error: ' .. tostring(err) .. ' in ' .. c.cmd)
    fn()
  end
end

core_vehicles = {
  getConfigList = function(arr) return {configs = env.configs} end,
  getModel = function(key) return {model = env.models[key], configs = {}} end,
  spawnNewVehicle = function(model, opts)
    if model == 'broken' then error('jbeam invalide (mod cassé)') end
    local pos = opts.pos
    if not pos then
      local pv = getPlayerVehicle(0)
      pos = pv and (pv.pos + vec3(5, 0, 0)) or vec3(0, 0, 10)
    end
    local v = newVeh(model, opts.config, pos, opts.rot)
    v.spawnOpts = opts
    if opts.autoEnterVehicle ~= false then
      local old = env.playerId
      env.playerId = v.id
      -- comme le jeu : hooks de spawn et de changement de véhicule
      if livraisonLibre and livraisonLibre.onVehicleSpawned then livraisonLibre.onVehicleSpawned(v.id) end
      if livraisonLibre and livraisonLibre.onVehicleSwitched then livraisonLibre.onVehicleSwitched(old, v.id, 0) end
    end
    return v, {v}
  end,
  replaceVehicle = function(model, opts, other)
    if model == 'broken' then return nil end -- comme le jeu : config illisible, rien n'est remplacé
    other = other or getPlayerVehicle(0)
    local s = SIZES[model] or {2.0, 4.8}
    other.model, other.config, other.w, other.l = model, opts.config, s[1], s[2]
    other.JBeam, other.partConfig = model, opts.config
    other.spawnOpts = opts
    if livraisonLibre and livraisonLibre.onVehicleReplaced then livraisonLibre.onVehicleReplaced(other.id) end
    return other, {other}
  end,
}
core_vehiclePaints = {
  getRandomPaints = function(m, c) return {paintName1 = 'Rouge', paintName2 = 'Rouge', paintName3 = 'Blanc'} end,
}

-- map, gps, rendu ------------------------------------------------------------
map = {
  getMap = function() return {nodes = env.nodes} end,
  getRoadRules = function() return {rightHandDrive = env.leftTraffic or false} end,
}
core_groundMarkers = {
  target = nil,
  setPath = function(wp, opts)
    core_groundMarkers.target = wp
    table.insert(env.paths, wp or false)
  end,
  currentlyHasTarget = function() return core_groundMarkers.target ~= nil end,
  getPathLength = function()
    local pv = getPlayerVehicle(0)
    if not pv or not core_groundMarkers.target then return 0 end
    return (pv.pos - core_groundMarkers.target):length() * 1.2
  end,
}
ui_fadeScreen = {
  fadeToBlack = function(t) table.insert(env.fades, 'black'); env.fadeBlackPending = 2 end,
  fadeFromBlack = function(t) table.insert(env.fades, 'clear') end,
}
Engine = {Render = {DynamicDecalMgr = {addDecals = function(tbl, n)
  env.decals = env.decals + 1
  env.lastDecal = {texture = tbl[1].texture, color = tbl[1].color, scale = vec3(tbl[1].scale), position = vec3(tbl[1].position)}
end}}}
debugDrawer = {
  drawCylinder = function(self, a, b, r, c)
    env.beams = env.beams + 1
    if math.abs((b.z - a.z) - 2) < 1e-6 then env.lastPost = {a = vec3(a), b = vec3(b), r = r, c = c} end
  end,
  drawSphere = function(self, p, r, c) env.lastPostTop = {p = vec3(p), r = r, c = c} end,
}
core_camera = {
  getPosition = function() return vec3(0, 0, 20) end,
  getQuat = function() return quatFromDir(vec3(0, 1, 0)) end,
}
spawn = {safeTeleport = function(veh, pos, rot) veh.pos = vec3(pos); veh.dir = vec3(rot.dir) end}
gameplay_walk = {isWalking = function() return false end}
function getCurrentLevelIdentifier() return env.level end
extensions = {load = function() end}

-- sites (parkings) -------------------------------------------------------------
gameplay_sites_sitesManager = {
  loadSites = function(file)
    local spots = {}
    local function add(name, x, y, fx, fy)
      spots[#spots + 1] = {name = name, pos = vec3(x, y, 10), rot = quatFromDir(vec3(fx, fy, 0)), scl = vec3(2.6, 6, 3)}
    end
    if file:find('city') then
      add('park1', 125, 60, 1, 0)
      add('park2', 365, 245, 0, 1)
      add('gas1', 610, 125, 1, 0)
    elseif file:find('residential') then
      add('house1', 245, 370, 0, 1)
      add('house2', 490, 610, 1, 0)
    else
      add('drift_should_be_skipped', 0, 0, 0, 1)
    end
    return {parkingSpots = {sorted = spots}}
  end,
}
freeroam_facilities = {
  getFacilities = function(lvl)
    return {gasStations = {{name = 'levels.testcity.gasStationPoints.apex.title', type = 'gasStation', parkingSpotNames = {'gas1'}}}}
  end,
}

-- écriture texte (CSV)
function writeFile(path, data) env.files[path] = data; return true end
function _tr(key, fallback) return env.translations and env.translations[key] or fallback or key end

-- trafic / voitures garées / police -----------------------------------------
env.traffic = {state = 'off', amount = 0, parked = 0, calls = {}, deletes = 0, scatters = 0, data = {}}
gameplay_traffic = {
  setupTrafficHelper = function(amount, opts, parked, popts)
    local t = env.traffic
    table.insert(t.calls, {amount = amount, police = opts and opts.police, parked = parked, llPoliceCount = opts and opts.llPoliceCount,
      providerRegistered = (t.providers and t.providers.livraisonLibrePolice) and true or false})
    t.state = 'loading'
    t.amount, t.parked = amount, parked
    env.trafficReadyIn = 20 -- frames avant onTrafficOrParkingReady
    env.policeCount = (opts and opts.police) and math.ceil(amount * 0.25) or (opts and opts.llPoliceCount or 0)
    return amount > 0, parked > 0
  end,
  setTrafficVars = function(v) env.traffic.vars = v end,
  registerSpecialVehicleProvider = function(pv)
    env.traffic.providers = env.traffic.providers or {}
    env.traffic.providers[pv.name] = pv
    env.traffic.lastProvider = pv
  end,
  unregisterSpecialVehicleProvider = function(name)
    if env.traffic.providers then env.traffic.providers[name] = nil end
  end,
  deleteVehicles = function() env.traffic.deletes = env.traffic.deletes + 1; env.traffic.amount = 0; env.traffic.state = 'off'; env.policeCount = 0 end,
  scatterTraffic = function() env.traffic.scatters = env.traffic.scatters + 1 end,
  forceTeleport = function(id, pos, dir, minDist, maxDist)
    env.traffic.teleported = env.traffic.teleported or {}
    table.insert(env.traffic.teleported, {id = id, minDist = minDist})
    local v = env.vehicles[id]
    if v then v.pos = vec3(pos.x + minDist, pos.y, pos.z) end
  end,
  getState = function() return env.traffic.state end,
  getTrafficAmount = function() return env.traffic.amount end,
  getTrafficData = function() return env.traffic.data end,
}
gameplay_parking = {
  getState = function() return env.traffic.parked > 0 end,
  deleteVehicles = function() env.traffic.parked = 0 end,
  scatterParkedCars = function() env.traffic.parkedScatters = (env.traffic.parkedScatters or 0) + 1 end,
  getParkedCarsAmount = function() return env.traffic.parked end,
  getParkingSpots = function() return env.parkingSpots end,
  getParkedCarsData = function() return env.parkedData or {} end,
  forceTeleport = function(id, pos, minDist, maxDist)
    env.parkedTeleported = env.parkedTeleported or {}
    table.insert(env.parkedTeleported, id)
    local v = env.vehicles[id]
    if v then v.pos = vec3(pos.x + 500, pos.y, pos.z) end
  end,
}
env.pursuitMode = 0
gameplay_police = {
  setPursuitVars = function(v) env.policeVars = env.policeVars or {}; for k, x in pairs(v or {}) do env.policeVars[k] = x end end,
  getPursuitVars = function()
    local d = {strictness = 0.5, suspectFrequency = 0.5, roadblockFrequency = 0.5, evadeTime = 45, evadeRadius = 80, arrestTime = 5}
    for k, x in pairs(env.policeVars or {}) do d[k] = x end
    return d
  end,
  setupPursuitGameplay = function(vid, ids, opts)
    if (env.policeCount or 0) > 0 then env.wantedVeh = vid; env.wantedLevel = opts and opts.pursuitMode; return true end
    return false
  end,
  setPursuitMode = function(mode, vid) env.lastPursuitReset = {mode = mode, vid = vid} end,
  getPursuitData = function(id) return env.pursuitData or {mode = env.pursuitMode, score = 0} end,
  getPoliceVehicles = function()
    local t = {}
    for i = 1, env.policeCount or 0 do t[9000 + i] = {} end
    return t
  end,
}
core_levels = {getLevelByName = function(n) return {supportsTraffic = env.supportsTraffic ~= false} end}
map.objects = {}

-- marqueur "attention"
package.preload['scenario/raceMarkers/attention'] = function()
  return function(id)
    local m = {id = id, updates = 0}
    function m:createMarkers() env.markerCreated = (env.markerCreated or 0) + 1 end
    function m:setToCheckpoint(wp) self.pos = wp.pos end
    function m:setMode(mode) end
    function m:show() end
    function m:update(dt, dtSim) self.updates = self.updates + 1 end
    function m:clearMarkers() env.markerCleared = (env.markerCleared or 0) + 1 end
    return m
  end
end

return env
