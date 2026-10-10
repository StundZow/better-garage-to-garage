-- Un joueur BeamMP simulé (utilisé par test_multi.py, un par environnement Lua) : le jeu (mock_env), la partie
-- client de BeamMP (messages vers et depuis le serveur) et le mod tel quel.
-- Variables posées avant : MP_ID, MP_NAME, OWN_X, OWN_Y, MP_SESSION (false : partie solo).
local env = require('mock_env')
local citygen = require('citygen')
local json = dofile(TEST_DIR .. '/json_lite.lua')
jsonEncode, jsonDecode = json.encode, json.decode

env.nodes = citygen.city(9, 120)
env.models = {
  sedanx = {Name = 'Sedan X', Type = 'Car', ['Body Style'] = 'Sedan', Years = {min = 2010, max = 2018}, paints = {Rouge = {baseColor = {1, 0, 0, 1}}, Blanc = {baseColor = {1, 1, 1, 1}}}},
  oldie = {Name = 'Oldie', Type = 'Car', ['Body Style'] = 'Coupe', Years = {min = 1965, max = 1970}, paints = {Rouge = {baseColor = {1, 0, 0, 1}}, Blanc = {baseColor = {1, 1, 1, 1}}}},
  modcar = {Name = 'Mod Car', Type = 'Car', ['Body Style'] = 'Sedan', Years = {min = 2015, max = 2020}},
}
env.SIZES.sedanx = {1.9, 4.7}
env.SIZES.oldie = {1.8, 4.3}
env.SIZES.modcar = {2.0, 4.9}
local function cfg(model, key, extra)
  local c = {model_key = model, key = key, pcFilename = '/vehicles/' .. model .. '/' .. key .. '.pc', Name = model .. ' ' .. key,
    Source = 'BeamNG - Official', preview = '/vehicles/' .. model .. '/' .. key .. '.jpg', ['Config Type'] = 'Factory'}
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end
env.configs = {cfg('sedanx', 'base'), cfg('sedanx', 'sport', {['0-100 km/h'] = 4.9}), cfg('oldie', 'base'), cfg('modcar', 'base', {Source = 'Mod'})}

local own = env.newVeh('sedanx', '/vehicles/sedanx/base.pc', vec3(OWN_X or 0, OWN_Y or 0, 10))
env.playerId = own.id

-- BeamMP côté client
MP_OUT = {}
local handlers = {}
MPCoreNetwork = {isMPSession = function() return MP_SESSION ~= false end}
MPConfig = {getPlayerServerID = function() return MP_ID end, getNickname = function() return MP_NAME end}
MPVehicleGE = {isOwn = function(id) local v = env.vehicles[id]; return v ~= nil and not v.remote end}
function TriggerServerEvent(name, data) MP_OUT[#MP_OUT + 1] = {name = name, data = data} end
function AddEventHandler(name, fn, tag) handlers[name] = fn end
function RemoveEventHandler(name, tag) handlers[name] = nil end
function MP_receive(name, data)
  local h = handlers[name]
  if h then h(data) end
  return h ~= nil
end
function MP_drain()
  local out = MP_OUT
  MP_OUT = {}
  return out
end

-- tous les messages de l'app (pas seulement le dernier)
env.toasts = {}
local origTrigger = guihooks.trigger
guihooks.trigger = function(name, data)
  if name == 'LivraisonLibreToast' and type(data) == 'table' then table.insert(env.toasts, data.msg) end
  return origTrigger(name, data)
end

M = dofile(MOD_ROOT .. '/lua/ge/extensions/livraisonLibre.lua')
livraisonLibre = M
ENV = env

-- zone de livraison dessinée (comme dans test_sim)
local origAdd = Engine.Render.DynamicDecalMgr.addDecals
Engine.Render.DynamicDecalMgr.addDecals = function(tbl, n)
  origAdd(tbl, n)
  local d = tbl[1]
  env.lastZone = {x = d.position.x, y = d.position.y, z = d.position.z, fx = d.forwardVec.x, fy = d.forwardVec.y, fz = d.forwardVec.z,
    ux = 0, uy = 0, uz = 1, w = d.scale.x, l = d.scale.y}
end

function frames(n, dt)
  dt = dt or 1 / 60
  for _ = 1, n do
    env.frame = env.frame + 1
    if env.fadeBlackPending then
      env.fadeBlackPending = env.fadeBlackPending - 1
      if env.fadeBlackPending <= 0 then env.fadeBlackPending = nil; M.onScreenFadeState(1) end
    end
    if env.trafficReadyIn then
      env.trafficReadyIn = env.trafficReadyIn - 1
      if env.trafficReadyIn <= 0 then env.trafficReadyIn = nil; env.traffic.state = 'on'; M.onTrafficOrParkingReady() end
    end
    M.onUpdate(dt, dt, dt)
    M.onPreRender(dt, dt, dt)
    env.flushVlua()
  end
end

function state() return env.events.LivraisonLibreState end
function sess() local s = state(); return s and s.session end
function myVeh() return getPlayerVehicle(0) end
function vehCount() local n = 0; for _ in pairs(env.vehicles) do n = n + 1 end; return n end

-- se gare dans sa zone, frein à main serré (validation)
function parkAndValidate()
  local z = env.lastZone
  local v = getPlayerVehicle(0)
  v.pos = vec3(z.x, z.y, z.z)
  v.dir = vec3(z.fx, z.fy, 0):normalized()
  v.vel = vec3(0, 0, 0)
  v.parkbrake = 1
  frames(90)
  v.parkbrake = 0
end

-- roule un peu (le chrono démarre), loin de la zone
function driveAway()
  local v = getPlayerVehicle(0)
  v.vel = vec3(15, 0, 0)
  frames(30)
  v.pos = vec3(-3000, -3000, 10)
  frames(10)
  v.vel = vec3(0, 0, 0)
end

M.onExtensionLoaded()
M.onClientPostStartMission('/levels/testcity/main.level.json')
M.requestMapInfo()
M.requestVehicles()
M.setSettings({minDist = 300, maxDist = 900, zoneScale = 1.3, timeLimit = true, timeLevel = 'moyen'})
