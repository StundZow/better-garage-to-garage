-- Simulation de parties complètes avec l'API BeamNG mockée
local env = require('mock_env')
local citygen = require('citygen')

local passed, failed = 0, 0
local function check(cond, name, extra)
  if cond then passed = passed + 1 else failed = failed + 1; print('  FAIL: ' .. name .. (extra ~= nil and (' -> ' .. tostring(extra)) or '')) end
end

env.nodes = citygen.city(9, 120)
env.translations = {['levels.testcity.gasStationPoints.apex.title'] = 'Station Apex'}

env.models = {
  sedanx = {Name = 'Sedan X', Type = 'Car', ['Body Style'] = 'Sedan', Years = {min = 2010, max = 2018}, paints = {Rouge = {baseColor = {1, 0, 0, 1}}, Blanc = {baseColor = {1, 1, 1, 1}}}},
  oldie = {Name = 'Oldie', Type = 'Car', ['Body Style'] = 'Coupe', Years = {min = 1965, max = 1970}, paints = {Rouge = {baseColor = {1, 0, 0, 1}}, Blanc = {baseColor = {1, 1, 1, 1}}}},
  hauler = {Name = 'Hauler', Type = 'Truck', ['Body Style'] = 'Fifth Wheel Truck', Years = {min = 1990, max = 2000}},
  cone = {Name = 'Cone', Type = 'Prop'},
  trailer = {Name = 'Trailer', Type = 'Trailer'},
}
env.SIZES.sedanx = {1.9, 4.7}
env.SIZES.oldie = {1.8, 4.3}
env.SIZES.hauler = {2.5, 7.5}
local function cfg(model, key, extra)
  local c = {model_key = model, key = key, pcFilename = '/vehicles/' .. model .. '/' .. key .. '.pc', Name = model .. ' ' .. key, Source = 'BeamNG - Official', preview = '/vehicles/' .. model .. '/' .. key .. '.jpg', ['Config Type'] = 'Factory'}
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end
env.configs = {
  cfg('sedanx', 'base', {Transmission = 'Automatic'}), cfg('sedanx', 'sport', {['0-100 km/h'] = 4.9, Transmission = 'Manual'}), cfg('sedanx', 'police', {['Config Type'] = 'Police'}),
  cfg('oldie', 'base'), cfg('hauler', 'base'), cfg('cone', 'base'), cfg('trailer', 'base'),
  cfg('sedanx', 'traffic', {Type = 'PropTraffic'}),
}

local own = env.newVeh('sedanx', '/vehicles/sedanx/base.pc', vec3(0, 0, 10))
env.playerId = own.id

local M = dofile(MOD_ROOT .. '/lua/ge/extensions/livraisonLibre.lua')
livraisonLibre = M
local allowedGlobals = {livraisonLibre = true, gameplay_playmodeMarkers = true}
setmetatable(_G, {__newindex = function(t, k, v)
  if not allowedGlobals[k] then error('écriture globale inattendue : ' .. tostring(k), 2) end
  rawset(t, k, v)
end})

local function frames(n, dt, dtSim)
  dt = dt or 1 / 60
  for i = 1, n do
    env.frame = env.frame + 1
    if env.fadeBlackPending then
      env.fadeBlackPending = env.fadeBlackPending - 1
      if env.fadeBlackPending <= 0 then env.fadeBlackPending = nil; M.onScreenFadeState(1) end
    end
    if env.trafficReadyIn then
      env.trafficReadyIn = env.trafficReadyIn - 1
      if env.trafficReadyIn <= 0 then env.trafficReadyIn = nil; env.traffic.state = 'on'; M.onTrafficOrParkingReady() end
    end
    M.onUpdate(dt, dtSim or dt, dt)
    M.onPreRender(dt, dtSim or dt, dt)
    env.flushVlua()
  end
end
local function state() return env.events.LivraisonLibreState end
local function sess() return state() and state().session end
local function hud() return env.events.LivraisonLibreHud end
local function errors()
  local n = 0
  for _, l in ipairs(env.logs) do if l.level == 'E' then n = n + 1; print('   E> ' .. tostring(l.msg)) end end
  return n
end
local function journalRecs() local j = env.files['/settings/livraisonLibre/livraisons.json']; return j and j.records or {} end
local function lastRec() local r = journalRecs(); return r[#r] end

local origAdd = Engine.Render.DynamicDecalMgr.addDecals
Engine.Render.DynamicDecalMgr.addDecals = function(tbl, n)
  origAdd(tbl, n)
  local d = tbl[1]
  env.lastZone = {x = d.position.x, y = d.position.y, z = d.position.z, fx = d.forwardVec.x, fy = d.forwardVec.y, fz = d.forwardVec.z, ux = 0, uy = 0, uz = 1, w = d.scale.x, l = d.scale.y}
end
local function parkInZone(offsetSide, yawDeg)
  local z = env.lastZone
  local v = getPlayerVehicle(0)
  local right = vec3(z.fx, z.fy, z.fz):cross(vec3(z.ux, z.uy, z.uz)):normalized()
  v.pos = vec3(z.x, z.y, z.z) + right * (offsetSide or 0)
  local f = vec3(z.fx, z.fy, 0)
  if yawDeg then
    local a = math.rad(yawDeg)
    f = vec3(z.fx * math.cos(a) - z.fy * math.sin(a), z.fx * math.sin(a) + z.fy * math.cos(a), 0)
  end
  v.dir = f:normalized()
  v.vel = vec3(0, 0, 0)
end
-- roule en ligne droite (simulation de distance parcourue) sans entrer dans la zone
local function drive(meters, speed)
  local v = getPlayerVehicle(0)
  speed = speed or 20
  v.pos = vec3(-3000, -3000, 10)
  v.vel = vec3(speed, 0, 0)
  local n = math.ceil(meters / speed * 60)
  frames(n)
  v.vel = vec3(0, 0, 0)
end
local function deliverNow()
  frames(2)
  parkInZone(0)
  getPlayerVehicle(0).parkbrake = 1
  frames(90)
  getPlayerVehicle(0).parkbrake = 0
end

print('-- chargement')
M.onExtensionLoaded()
M.onClientPostStartMission('/levels/testcity/main.level.json')
check(state() and state().level == 'testcity', 'state envoyé avec la map')
check(state().settings.traffic.mode == 'keep', 'trafic : ne rien changer par défaut')
check(state().journal and state().journal.count == 0, 'journal vide')
M.requestMapInfo()
check(state().levelReady == true, 'map analysée')
M.requestVehicles()
M.setSettings({minDist = 300, maxDist = 900, zoneScale = 1.3})

print('-- sauvegarde des réglages')
M.setSettings({traffic = {mode = 'on', amount = 99, parked = -3, police = 'wanted', wantedLevel = 7}})
local st = env.files['/settings/livraisonLibre/settings.json']
check(st.traffic.mode == 'on' and st.traffic.amount == 40 and st.traffic.parked == 0 and st.traffic.wantedLevel == 5, 'réglages trafic assainis et sauvegardés')
M.setSettings({summaryDuration = 99, traffic = {policeRatio = 2}})
st = env.files['/settings/livraisonLibre/settings.json']
check(st.summaryDuration == 15 and st.traffic.policeRatio == 0.75, 'durée du résumé et ratio police bornés', tostring(st.summaryDuration) .. ' / ' .. tostring(st.traffic.policeRatio))
M.setSettings({summaryDuration = 5, traffic = {policeRatio = 0.25}})
M.setUiPrefs({tab = 'plus', collapsed = true})
check(env.files['/settings/livraisonLibre/settings.json'].ui.tab == 'plus', 'onglet mémorisé côté jeu')
M.setUiPrefs({tab = 'stats'})
check(env.files['/settings/livraisonLibre/settings.json'].ui.tab == 'plus', 'ancien onglet converti (stats -> plus)')
M.setUiPrefs({tab = 'trafic'})
check(env.files['/settings/livraisonLibre/settings.json'].ui.tab == 'police', 'ancien onglet converti (trafic -> police)')
M.setUiPrefs({tab = 'plus', collapsed = true})
M.setSettings({ui = {tab = 'lieux'}})
check(env.files['/settings/livraisonLibre/settings.json'].ui.tab == 'plus', 'setSettings ne touche pas à l état de l UI')
-- rechargement complet : tout doit revenir
local M2 = dofile(MOD_ROOT .. '/lua/ge/extensions/livraisonLibre.lua')
local saveEvents = env.events.LivraisonLibreState
M2.onExtensionLoaded()
M2.requestState()
local s2 = state().settings
check(s2.minDist == 300 and s2.maxDist == 900 and s2.traffic.mode == 'on' and s2.traffic.police == 'wanted' and s2.ui.tab == 'plus', 'réglages relus après redémarrage')
M.setSettings({traffic = {mode = 'keep', police = 'off', amount = 8, parked = 6}})

print('-- 1re livraison')
M.start()
frames(5)
local newPlayer = getPlayerVehicle(0)
check(newPlayer and newPlayer.id ~= own.id and env.vehicles[own.id] == nil, 'nouveau véhicule, ancien supprimé')
frames(40)
check(sess().phase == 'driving', 'en route', sess().phase)
check(#env.traffic.calls == 0, 'mode « ne pas toucher » : trafic intact')
check(sess().vehicle.model == newPlayer.JBeam, 'le spawn n est pas pris pour un changement de véhicule')

print('-- repère vertical au centre de la place')
env.lastPost = nil
frames(2)
local post, zc = env.lastPost, env.lastZone
check(post ~= nil, 'trait vertical dessiné')
check(post and math.abs(post.a.x - zc.x) < 1e-6 and math.abs(post.a.y - zc.y) < 1e-6 and math.abs(post.a.z - zc.z) < 1e-6, 'trait au centre de la place')
check(post and math.abs(post.b.z - post.a.z - 2) < 1e-6, 'trait de 2 m de haut')
check(post and post.c == env.lastDecal.color and post.c.r > 0.8, 'trait rouge comme la zone')
check(env.lastPostTop and math.abs(env.lastPostTop.p.z - post.b.z) < 1e-6, 'boule en haut du trait')
parkInZone(0)
frames(10)
check(env.lastPost.c.b > 0.9 and env.lastPost.c == env.lastDecal.color, 'trait bleu quand bien garé, comme la zone')
check(sess().phase == 'driving', 'pas validé sans frein à main')

print('-- réglages verrouillés en mission')
M.setSettings({minDist = 5000})
check(env.files['/settings/livraisonLibre/settings.json'].minDist == 300, 'réglages refusés pendant une livraison')

print('-- mesures : distance, vitesse, resets, dégâts')
frames(60 * 3)
check(hud().chronoState == 'wait' and hud().elapsed == 0, 'chrono du trajet en attente tant qu on n accélère pas', hud().chronoState)
drive(400, 20)
check(hud().chronoState == 'running' and math.abs(hud().elapsed - 20) < 0.5, 'chrono démarré à la 1re accélération (attente exclue)', hud().elapsed)
check(hud().total > hud().elapsed + 2.5, 'temps total inclut l attente')
check(hud().odo and math.abs(hud().odo - 400) < 25, 'distance parcourue mesurée', hud().odo)
check(hud().vmaxKmh and math.abs(hud().vmaxKmh - 72) < 1, 'vitesse max', hud().vmaxKmh)
M.trackVehReset(); M.trackVehReset()
check(hud() and true, 'hud')
frames(15)
check(hud().resets == 2, 'resets comptés', hud().resets)
map.objects[newPlayer.id] = {damage = 1200}
frames(20)
map.objects[newPlayer.id] = {damage = 0}   -- reset : dégâts remis à zéro par le jeu
frames(20)
map.objects[newPlayer.id] = {damage = 300}
frames(20)
check(hud().damage == 1500, 'dégâts cumulés malgré le reset', hud().damage)
-- pics de vitesse parasites (choc, reset, récupération) : ignorés
local pv = getPlayerVehicle(0)
local vmaxBefore, odoBefore = hud().vmaxKmh, hud().odo
pv.vel = vec3(140, 0, 0); frames(1); pv.vel = vec3(0, 0, 0); frames(20)
check(math.abs(hud().vmaxKmh - vmaxBefore) < 0.5, 'pic de vitesse d une frame ignoré (vitesse max)', hud().vmaxKmh)
check(math.abs(hud().odo - odoBefore) < 3, 'pic de vitesse sans effet sur la distance', hud().odo - odoBefore)
M.trackVehReset()
pv.vel = vec3(100, 0, 0); frames(30); pv.vel = vec3(0, 0, 0); frames(20)
check(math.abs(hud().vmaxKmh - vmaxBefore) < 0.5, 'vitesse ignorée juste après un reset', hud().vmaxKmh)
check(hud().resets == 3, 'reset compté', hud().resets)

print('-- changement de véhicule par le joueur (< 500 m : non noté)')
local v2 = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(-3000, -3000, 10))
local prevId = env.playerId
env.playerId = v2.id
M.onVehicleSwitched(prevId, v2.id, 0)
frames(15)
check(sess().vehicle.model == 'oldie', 'interface mise à jour avec le nouveau véhicule', sess().vehicle.model)
check(hud().switches == 0, 'premier véhicule (400 m) non compté', hud().switches)
check(math.abs(env.lastZone.w - 1.8 * 1.3) < 1e-6, 'zone adaptée au nouveau gabarit', env.lastZone.w)
drive(700, 25)
local v3 = env.newVeh('sedanx', '/vehicles/sedanx/sport.pc', vec3(-3000, -3000, 10))
prevId = env.playerId
env.playerId = v3.id
M.onVehicleSwitched(prevId, v3.id, 0)
frames(15)
check(hud().switches == 1, 'véhicule utilisé > 500 m compté comme changement', hud().switches)
-- trafic / voitures garées / unicycle ne sont jamais adoptés
local ai = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(0, 0, 10))
env.traffic.data[ai.id] = {isAi = true}
M.onVehicleSwitched(v3.id, ai.id, 0)
check(sess().vehicle.model == 'sedanx', 'véhicule de trafic ignoré')
env.playerId = v3.id

print('-- livraison + journal')
local tripBefore = hud().elapsed
local summaryCount = env.eventCount.LivraisonLibreSummary or 0
deliverNow()
check(sess().phase == 'summary', 'livrée', sess().phase)
check((env.eventCount.LivraisonLibreSummary or 0) == summaryCount, 'résumé retenu tant que la livraison suivante n est pas chargée')
frames(60 * 4)
check(sess().phase == 'driving', 'livraison suivante chargée', sess().phase)
check((env.eventCount.LivraisonLibreSummary or 0) == summaryCount, 'résumé pas encore affiché juste après le fondu')
frames(60)
check((env.eventCount.LivraisonLibreSummary or 0) == summaryCount + 1, 'résumé affiché une fois la livraison suivante chargée')
local sum = env.events.LivraisonLibreSummary
check(sum and sum.ok == true and sum.showFor == 5, 'écran de résumé (5 s)')
check(sum and math.abs(sum.tripTime - tripBefore) < 0.6, 'chrono arrêté à 50 m de la zone (stationnement exclu)', sum and sum.tripTime)
check(sum and sum.parkTime and sum.parkTime > 0.3, 'temps de stationnement mesuré à part', sum and sum.parkTime)
check(sum and math.abs(sum.avgKmh - (sum.tripDist / sum.tripTime * 3.6)) < 0.01, 'vitesse moyenne = distance chronométrée / temps')
local rec = lastRec()
check(rec ~= nil and rec.result == 'Livrée', 'ligne de journal créée', rec and rec.result)
check(rec.resets == 3 and rec.switches == 1, 'resets et changements dans le journal', tostring(rec.resets) .. '/' .. tostring(rec.switches))
check(rec.vehiclesUsed:find('^oldie base') and not rec.vehiclesUsed:find('sedanx base'), 'véhicules utilisés (le 1er à 400 m ignoré)', rec.vehiclesUsed)
check(rec.drivenKm >= 1.0 and rec.damage == 1500, 'distance et dégâts', tostring(rec.drivenKm) .. ' / ' .. tostring(rec.damage))
check(rec.traffic == 'Non' and rec.map == 'testcity' and rec.timeText ~= nil, 'trafic / map / temps')
local csv = env.files['/settings/livraisonLibre/livraisons.csv']
check(type(csv) == 'string' and csv:sub(1, 3) == '\239\187\191' and csv:find('Vitesse moyenne') and csv:find('Resets'), 'CSV écrit avec en-têtes (UTF-8 BOM)')
local lines = 0 for _ in csv:gmatch('\r\n') do lines = lines + 1 end
check(lines == 2, 'CSV : en-tête + 1 livraison', lines)
check(state().journal.count == 1, 'compteur de journal dans l UI')
check(state().stats.history[1].resets == 3, 'historique UI avec resets')

print('-- passer / changer de destination / arrêter : notés aussi')
check(sess().phase == 'driving', 'livraison suivante', sess().phase)
M.rerollDestination()
check(lastRec().result == 'Destination changée', 'destination changée notée')
frames(5)
M.skip()
check(lastRec().result == 'Passée', 'passée notée')
frames(60)
check(sess().phase == 'driving', 'en route', sess().phase)
M.stop()
check(lastRec().result == 'Arrêtée' and #journalRecs() == 4, 'arrêtée notée', #journalRecs())

print('-- trafic avec police (patrouilles)')
M.setSettings({traffic = {mode = 'on', amount = 10, parked = 5, police = 'patrol', strictness = 0.8, removeOnStop = true}})
M.start()
frames(5)
local c1 = env.traffic.calls[1]
check(#env.traffic.calls == 1 and c1.amount == 10 and c1.parked == 5, 'trafic lancé (10 + 5 garées)')
check(c1.police == false and c1.llPoliceCount == 3 and c1.providerRegistered, 'police au ratio choisi (25 % de 10 = 3) via le fournisseur du mod', tostring(c1.llPoliceCount))
check(env.traffic.lastProvider.guaranteed == 3 and env.traffic.lastProvider.getDesiredCount(10, {llPoliceCount = 3}) == 3
  and env.traffic.lastProvider.getDesiredCount(10, {}) == 0, 'fournisseur inerte pour le trafic lancé par le jeu')
check(env.traffic.providers.livraisonLibrePolice == nil, 'fournisseur retiré après la création du trafic')
check(env.policeVars and env.policeVars.strictness == 0.8, 'sévérité de la police appliquée')
frames(10)
check(sess().phase == 'spawning' and sess().loadingTraffic == true, 'attente du trafic (écran noir)', sess().phase)
frames(40)
check(sess().phase == 'driving', 'en route après chargement du trafic', sess().phase)
check(hud().traffic and hud().traffic.amount == 10 and hud().traffic.police == 3, 'infos trafic dans le HUD')
deliverNow()
check(lastRec().traffic == 'Oui' and lastRec().trafficCount == 10 and lastRec().police == 'Patrouilles', 'trafic noté dans le journal')
frames(60 * 4)
check(sess().phase == 'driving' and env.traffic.scatters >= 1, 'trafic rapproché après téléport', env.traffic.scatters)
check(#env.traffic.calls == 1, 'trafic créé une seule fois par session')
M.stop()
check(env.traffic.deletes >= 1 and env.traffic.amount == 0, 'trafic retiré à l arrêt')

print('-- mode recherché + arrestation')
M.setSettings({traffic = {mode = 'on', police = 'wanted', wantedLevel = 4, arrestFails = true}})
M.start()
frames(80)
check(sess().phase == 'driving', 'en route', sess().phase)
check(hud().stars == 0 and hud().policeOn == true, 'étoiles affichées (0) quand la police est active')
for _ = 1, 60 * 6 do -- la recherche s'arme 2,5 s après le début de la livraison (chargement du trafic compris)
  frames(1)
  if env.wantedVeh then break end
end
check(env.wantedVeh == getPlayerVehicle(0).id and env.wantedLevel == 2, 'recherché : 4 étoiles -> niveau 2 du jeu', env.wantedLevel)
env.pursuitData = {mode = 1, score = 150}
M.onPursuitAction(getPlayerVehicle(0).id, 'start', env.pursuitData)
check(env.pursuitData.score == 1200, 'la poursuite démarre à 4 étoiles (score relevé)', env.pursuitData.score)
env.pursuitData.mode = 2
frames(40)
check(hud().stars == 4 and hud().pursuit == 2, 'étoiles dans le HUD', hud().stars)
env.pursuitData = {mode = 1, score = 120}; frames(40)
check(hud().stars == 1, '1 étoile au début d une poursuite', hud().stars)
env.pursuitData = {mode = 1, score = 320}; frames(40)
check(hud().stars == 2, '2 étoiles', hud().stars)
env.pursuitData = {mode = 3, score = 2100}; frames(40)
check(hud().stars == 5, '5 étoiles au niveau max', hud().stars)
env.pursuitData = {mode = 0, score = 0}; frames(40)
check(hud().stars == 0, 'plus d étoiles quand la poursuite s arrête', hud().stars)
env.pursuitData = {mode = 2, score = 600}; frames(60 * 10)
env.pursuitMode = 2
M.onPursuitAction(getPlayerVehicle(0).id, 'arrest', {})
check(sess().phase == 'failed' and sess().summary.reason == 'Arrêté par la police', 'arrestation = livraison ratée')
check(lastRec().result == 'Ratée' and lastRec().pursuits == 1 and lastRec().arrests == 1 and lastRec().police == 'Recherché', 'poursuite/arrestation dans le journal')
check(lastRec().maxStars == 5, 'étoiles max dans le journal', lastRec().maxStars)
env.pursuitMode = 0
env.pursuitData = nil
M.stop()
check(env.events.LivraisonLibreSummary.maxStars == 5 and env.events.LivraisonLibreSummary.policeActive, 'étoiles max dans le résumé')
local ptime = env.events.LivraisonLibreSummary.pursuitTime
check(ptime and ptime > 9 and ptime < 14, 'temps survécu aux étoiles mesuré (~11 s)', ptime)
check(lastRec().pursuitTimeS and lastRec().pursuitTimeS >= 9, 'temps en poursuite dans le journal', lastRec().pursuitTimeS)

print('-- police écartée près de l arrivée')
M.setSettings({traffic = {mode = 'on', police = 'patrol', clearPoliceNearEnd = true}})
M.start()
frames(80)
local z0 = env.lastZone
local copNear = env.newVeh('sedanx', '/vehicles/sedanx/police.pc', vec3(z0.x + 30, z0.y, z0.z))
local copFar = env.newVeh('sedanx', '/vehicles/sedanx/police.pc', vec3(z0.x + 2000, z0.y, z0.z))
env.traffic.data = {[copNear.id] = {isAi = true, roleName = 'police'}, [copFar.id] = {isAi = true, roleName = 'police'}}
env.pursuitData = {mode = 2, score = 700}
env.traffic.teleported = {}
getPlayerVehicle(0).pos = vec3(z0.x + 250, z0.y, z0.z)
frames(60 * 2)
check(#env.traffic.teleported == 0, 'pas d effet loin de l arrivée')
getPlayerVehicle(0).pos = vec3(z0.x + 60, z0.y, z0.z)
frames(60 * 2)
check(#env.traffic.teleported == 1 and env.traffic.teleported[1].id == copNear.id, 'voiture de police proche envoyée plus loin', #env.traffic.teleported)
check(env.lastPursuitReset and env.lastPursuitReset.mode == 0 and env.lastPursuitReset.vid == getPlayerVehicle(0).id, 'poursuite terminée près de l arrivée')
env.pursuitData = nil
env.traffic.data = {}
copNear:delete(); copFar:delete()
M.stop()
M.setSettings({traffic = {mode = 'keep', police = 'off'}})

print('-- PNJ et sirènes')
M.setSettings({traffic = {mode = 'keep', civiliansIgnoreSirens = true, policeNoSiren = true}})
local civ = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(200, 200, 10))
local cop = env.newVeh('sedanx', '/vehicles/sedanx/police.pc', vec3(210, 200, 10))
local ownCar = env.newVeh('sedanx', '/vehicles/sedanx/base.pc', vec3(220, 200, 10))
env.traffic.data = {[civ.id] = {isAi = true, roleName = 'standard'}, [cop.id] = {isAi = true, roleName = 'police'}}
M.start()
frames(60 * 3)
env.flushVlua()
local seen = env.vmFor(civ).mapmgr.getObjects()
check(seen[1].states.lightbar == nil, 'le PNJ ne voit plus les sirènes (ne se range plus)')
check(env.vmFor(civ).electrics._llOrigLightbar == nil, 'le PNJ garde ses propres feux')
env.vmFor(cop).electrics.set_lightbar_signal(2)
check(cop.lightbar == 0, 'police sans gyrophares (option de secours)', cop.lightbar)
check(ownCar.vm == nil, 'véhicules hors trafic jamais modifiés')
M.stop()
env.flushVlua()
seen = env.vmFor(civ).mapmgr.getObjects()
check(seen[1].states.lightbar == 2, 'comportement normal rétabli à l arrêt')
env.vmFor(cop).electrics.set_lightbar_signal(2)
check(cop.lightbar == 2, 'gyrophares de la police rétablis à l arrêt')
M.setSettings({traffic = {civiliansIgnoreSirens = false, policeNoSiren = false}})
M.start()
frames(60 * 3)
env.flushVlua()
seen = env.vmFor(civ).mapmgr.getObjects()
check(seen[1].states.lightbar == 2, 'option désactivée : comportement du jeu inchangé')
M.stop()
env.traffic.data = {}
civ:delete(); cop:delete(); ownCar:delete()
M.setSettings({traffic = {civiliansIgnoreSirens = true}})

print('-- temps limite (sur le chrono du trajet)')
M.setSettings({traffic = {mode = 'keep'}, timeLimit = true, avgSpeedKmh = 200, timeBonus = 0})
M.start()
frames(60)
check(sess().phase == 'driving' and sess().timeLimit ~= nil, 'temps limite actif', sess().timeLimit)
frames(60 * 5)
check(sess().phase == 'driving', 'pas d échec tant qu on n a pas démarré')
drive(sess().timeLimit * 10 + 100, 10)
check(lastRec().result == 'Ratée' and lastRec().reason == 'Temps écoulé', 'échec temps écoulé noté', lastRec().result)
M.stop()
check(env.events.LivraisonLibreSummary.ok == false and env.events.LivraisonLibreSummary.reason == 'Temps écoulé', 'résumé de l échec affiché à l arrêt')
M.setSettings({timeLimit = false})

print('-- durée du résumé et repères désactivables')
M.setSettings({traffic = {mode = 'keep'}, summaryDuration = 12, showCenterPost = false, showBeam = false, showArrow = false})
local markersBefore = env.markerCreated or 0
M.start()
frames(60)
env.lastPost = nil
local beamsBefore = env.beams
getPlayerVehicle(0).pos = vec3(-3000, -3000, 10)
frames(30)
check(env.lastPost == nil, 'trait central masqué')
check(env.beams == beamsBefore, 'colonne lumineuse masquée')
check((env.markerCreated or 0) == markersBefore, 'flèche masquée')
M.stop()
M.previewSummary()
check(env.events.LivraisonLibreSummary.isPreview == true and env.events.LivraisonLibreSummary.preview ~= true, 'aperçu disponible (drapeau séparé de l image)')
M.start()
frames(60)
deliverNow()
M.stop()
check(env.events.LivraisonLibreSummary.showFor == 12, 'résumé affiché 12 s (réglage)', env.events.LivraisonLibreSummary.showFor)
M.setSettings({summaryDuration = 5, showCenterPost = true, showBeam = true, showArrow = true})

print('-- sans trafic')
M.setSettings({traffic = {mode = 'off'}})
env.traffic.amount = 7; env.traffic.state = 'on'
M.start()
frames(60)
check(env.traffic.amount == 0, 'trafic supprimé en mode sans trafic')
M.stop()

print('-- validation éclair')
M.setSettings({traffic = {mode = 'keep'}, instantNext = true, autoNext = false})
M.start()
frames(60)
check(sess().phase == 'driving', 'en route')
local before = #journalRecs()
frames(2)
parkInZone(0)
getPlayerVehicle(0).parkbrake = 1
frames(14)  -- ~0,23 s : le frein à main est lu toutes les 0,15 s
frames(12)
check(#journalRecs() == before + 1, 'validé en moins de 0,5 s', #journalRecs() - before)
check(sess().phase == 'fading' or sess().phase == 'spawning', 'livraison suivante lancée directement', sess().phase)
local sc = env.eventCount.LivraisonLibreSummary or 0
local lastSum = env.events.LivraisonLibreSummary
frames(60)
check(sess().phase == 'driving', 'nouvelle livraison en route', sess().phase)
frames(60)
check((env.eventCount.LivraisonLibreSummary or 0) == sc + 1 and env.events.LivraisonLibreSummary ~= lastSum and env.events.LivraisonLibreSummary.ok, 'validation éclair : résumé affiché après le chargement')
M.stop()
M.setSettings({instantNext = false, autoNext = true})

print('-- camion sur une place trop petite : zone déplacée')
M.setSettings({locKinds = {road = false, parking = true, poi = true, home = false}})
M.start()
frames(60)
check(sess().to.kind == 'parking' or sess().to.kind == 'poi', 'destination sur une place', sess().to.kind)
local truck = env.newVeh('hauler', '/vehicles/hauler/base.pc', vec3(-3000, -3000, 10))
prevId = env.playerId
env.playerId = truck.id
M.onVehicleSwitched(prevId, truck.id, 0)
frames(5)
check(sess().vehicle.model == 'hauler', 'camion adopté')
check(sess().to.kind ~= 'parking' and sess().to.kind ~= 'poi', 'livraison déplacée vers un emplacement compatible', sess().to.kind)
check(math.abs(env.lastZone.l - 7.5 * 1.3) < 1e-6, 'zone à la taille du camion', env.lastZone.l)
M.stop()
M.setSettings({locKinds = {road = true, parking = true, poi = true, home = true}})

print('-- véhicule perdu puis nouveau véhicule du joueur')
M.start()
frames(60)
local lost = getPlayerVehicle(0)
lost:delete()
frames(5)
check(sess().phase == 'lost', 'véhicule perdu', sess().phase)
local repl = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(0, 0, 10))
env.playerId = repl.id
M.onVehicleSwitched(-1, repl.id, 0)
frames(5)
check(sess().phase == 'driving' and sess().vehicle.model == 'oldie', 'mission reprise avec le nouveau véhicule', sess().phase)
M.stop()

print('-- remplacement via le sélecteur (même objet)')
M.start()
frames(60)
local cur = getPlayerVehicle(0)
local wantModel = cur.JBeam == 'oldie' and 'sedanx' or 'oldie'
cur.JBeam, cur.partConfig, cur.w, cur.l = wantModel, '/vehicles/' .. wantModel .. '/base.pc', env.SIZES[wantModel][1], env.SIZES[wantModel][2]
M.onVehicleReplaced(cur.id)
frames(5)
check(sess().vehicle.model == wantModel, 'remplacement détecté et interface mise à jour', sess().vehicle.model)
-- modification de pièces seulement (config non enregistrée) : pas un changement
local sw = hud().switches
cur.partConfig = {parts = {}}
M.onVehicleSpawned(cur.id)
frames(5)
check(sess().vehicle.model == wantModel and hud().switches == sw, 'édition des pièces : même véhicule')
M.stop()

print('-- autre véhicule (bouton) garde le chrono')
M.start()
frames(60)
frames(60 * 5)
local el = hud().elapsed
M.rerollVehicle()
frames(40)
check(sess().phase == 'driving' and hud().elapsed >= el, 'chrono conservé', hud().elapsed)
M.stop()

print('-- 1 seul point -> message')
M.setSettings({locMode = 'custom'})
M.start()
check(sess() == nil and env.events.LivraisonLibreToast.msg:find('au moins 2'), 'message explicite')
M.setSettings({locMode = 'random'})

print('-- changement de map')
M.start()
frames(60)
M.onClientEndMission()
check(state().session == nil, 'session arrêtée au changement de map')

M.previewSummary()
check(env.events.LivraisonLibreSummary.isPreview == true, 'aperçu du résumé')
local csvAll = env.files['/settings/livraisonLibre/livraisons.csv']
local hdr, l1 = csvAll:match('^\239\187\191([^\r]*)\r\n([^\r]*)\r\n')
print('  CSV en-tête : ' .. hdr)
print('  CSV ligne 1 : ' .. l1)
local nh, n1 = 0, 0
for _ in hdr:gmatch(';') do nh = nh + 1 end
for _ in l1:gmatch(';') do n1 = n1 + 1 end
check(nh == n1, 'CSV : même nombre de colonnes', nh .. '/' .. n1)
M.openDataFolder()
M.onExtensionUnloaded()
check(errors() == 0, 'aucune erreur loggée')

print('-- v1.3 : analyse de la map étalée sur plusieurs images')
M.onClientPostStartMission('/levels/testcity/main.level.json')
local realClock = os.clock
local fake = 0
os.clock = function() fake = fake + 0.004; return fake end -- chaque appel "coûte" 4 ms
M.requestMapInfo()
check(state().analysing == true and not state().levelReady, 'analyse en cours après la première image', tostring(state().analysing))
frames(400)
check(state().levelReady == true and not state().analysing, 'analyse terminée après quelques images')
local atxt = env.files['/settings/livraisonLibre/analyse.txt']
check(type(atxt) == 'string' and atxt:find('TERMIN'), 'étapes écrites dans analyse.txt')
print('  ' .. tostring(atxt):gsub('\n', '\n  '))

print('-- v1.3 : analyse trop longue -> abandon avec message, le jeu continue')
M.onClientPostStartMission('/levels/testcity/main.level.json')
os.clock = function() fake = fake + 20; return fake end -- chaque appel "coûte" 20 s
M.requestMapInfo()
frames(200)
check(not state().analysing and not state().levelReady, 'analyse abandonnée')
local tmsg = env.events.LivraisonLibreToast and env.events.LivraisonLibreToast.msg
check(tmsg and tmsg:find('trop longue'), 'message « analyse trop longue »', tmsg)
check(tostring(env.files['/settings/livraisonLibre/analyse.txt']):find('ÉCHEC'), 'échec noté dans analyse.txt')
os.clock = realClock

print('-- v1.3 : lancer sans analyse préalable')
M.onClientPostStartMission('/levels/testcity/main.level.json')
os.clock = function() fake = fake + 0.004; return fake end
M.setSettings({traffic = {mode = 'keep', police = 'off'}, ffbGuard = true, instantNext = false, autoNext = true})
M.start()
check(state().startPending == true and not sess(), 'lancement en attente de l analyse')
frames(400)
os.clock = realClock
check(sess() ~= nil, 'livraison lancée une fois la map analysée')
frames(120)
check(sess() and sess().phase == 'driving', 'en route', sess() and sess().phase)

print('-- v1.3 : retour de force coupé pendant le chargement')
local function vcmds(id, what)
  local n = 0
  for _, c in ipairs(env.vluaLog or {}) do
    if c.veh.id == id and c.cmd:find(what, 1, true) then n = n + 1 end
  end
  return n
end
local vid1 = getPlayerVehicle(0).id
check(env.vehicles[vid1].vm.hydros.enableFFB == true and env.vehicles[vid1].vm.hydros._llFfbHold == nil, 'retour de force actif une fois en route')
check(vcmds(vid1, 'hydros.enableFFB = false') >= 1, 'volant coupé sur le véhicule de livraison pendant le chargement')
check(vcmds(vid1, 'hydros.enableFFB = hydros._llFfbHold') >= 1, 'volant rendu après le retour de l image')
env.vluaLog = {}
M.skip()
frames(5)
check(vcmds(vid1, 'hydros.enableFFB = false') >= 1, 'coupé aussi au début du chargement suivant')
frames(400)
local vid2 = getPlayerVehicle(0).id
check(vid2 ~= vid1 and vcmds(vid2, 'hydros.enableFFB = false') >= 1 and vcmds(vid2, 'hydros.enableFFB = hydros._llFfbHold') >= 1, 'nouveau véhicule : coupé puis rendu')
check(env.vehicles[vid2].ffbForce == 0, 'force du volant remise à zéro au moment de la coupure')
check(env.vehicles[vid2].vm.hydros.enableFFB == true and env.vehicles[vid2].vm.hydros._llFfbHold == nil, 'retour de force rétabli normalement')

print('-- v1.3 : places du parking du jeu réservées et voiture garée déplacée')
M.stop()
-- places "du jeu" partout autour des noeuds de la ville (copie différente de celle du mod)
env.parkingSpots = {sorted = {}}
for _, n in pairs(env.nodes) do
  table.insert(env.parkingSpots.sorted, {name = 'ps', pos = vec3(n.pos.x + 3, n.pos.y, n.pos.z)})
end
M.start()
frames(400)
check(sess() and sess().phase == 'driving', 'en route (places du jeu)')
local z = env.lastZone
local reserved, near = 0, 0
for _, ps in ipairs(env.parkingSpots.sorted) do
  local d = math.sqrt((ps.pos.x - z.x) ^ 2 + (ps.pos.y - z.y) ^ 2)
  if d < 4 then near = near + 1; if ps.vehicle then reserved = reserved + 1 end end
end
check(reserved == near, 'places du jeu sur la zone réservées', reserved .. '/' .. near)
-- une voiture garée du jeu posée sur la zone pendant que le joueur est loin
local parkedCar = env.newVeh('sedanx', '/vehicles/sedanx/base.pc', vec3(z.x, z.y, z.z))
env.parkedData = {[parkedCar.id] = {}}
env.parkedTeleported = {}
getPlayerVehicle(0).pos = vec3(z.x + 400, z.y, z.z)
frames(90)
check(#env.parkedTeleported == 1 and env.parkedTeleported[1] == parkedCar.id, 'voiture garée déplacée hors de la place', #env.parkedTeleported)
-- une voiture quelconque (hors trafic) n'est jamais touchée
local otherCar = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(z.x, z.y, z.z))
env.parkedTeleported = {}
frames(90)
check(#env.parkedTeleported == 0, 'véhicule hors trafic jamais déplacé')
otherCar:delete(); parkedCar:delete(); env.parkedData = nil
M.stop()
local still = 0
for _, ps in ipairs(env.parkingSpots.sorted) do if ps.vehicle then still = still + 1 end end
check(still == 0, 'réservations libérées à l arrêt', still)
env.parkingSpots = nil

print('-- v1.3 : difficulté progressive selon les étoiles')
M.setSettings({traffic = {mode = 'on', police = 'patrol', progressive = true}})
M.start()
frames(400)
check(sess() and sess().phase == 'driving', 'en route (police)')
local pvid = getPlayerVehicle(0).id
local cop = env.newVeh('sedanx', '/vehicles/sedanx/police.pc', vec3(-2000, -2000, 10))
local farCop = env.newVeh('sedanx', '/vehicles/sedanx/police.pc', vec3(-2900, -2900, 10))
env.traffic.data = {
  [cop.id] = {isAi = true, roleName = 'police', role = {name = 'police', targetId = pvid, flags = {pursuit = 1}}},
  [farCop.id] = {isAi = true, roleName = 'police', model = 'md_series', role = {name = 'police', flags = {}}},
}
getPlayerVehicle(0).pos = vec3(1500, 1500, 10)
env.vluaLog = {}
env.pursuitData = {mode = 1, score = 120}; frames(30)
check(env.policeVars and env.policeVars.roadblockFrequency == 0 and env.policeVars.evadeTime == 25, '1 étoile : pas de barrage, facile à semer')
check(vcmds(cop.id, 'ai.setAggression(0.3)') == 1, '1 étoile : police peu agressive')
env.pursuitData = {mode = 2, score = 600}; frames(30)
check(vcmds(cop.id, 'ai.setAggression(0.9)') == 1, '3 étoiles : police agressive')
env.traffic.teleported = {}
env.pursuitData = {mode = 3, score = 2100}; frames(30 * 25)
check(env.policeVars.roadblockFrequency == 1 and env.policeVars.evadeTime == 80, '5 étoiles : barrages fréquents, dur à semer')
check(env.traffic.teleported[1] and env.traffic.teleported[1].id == farCop.id, '5 étoiles : renforts (police lourde en priorité) amenés près du joueur')
env.pursuitData = nil
env.traffic.data = {}
cop:delete(); farCop:delete()
deliverNow()
frames(10)
check(state().stats.history[1].maxStars == 5, 'étoiles max dans l historique', state().stats.history[1].maxStars)
M.stop()
check(env.policeVars.roadblockFrequency == 0.5 and env.policeVars.evadeTime == 45, 'réglages de police du jeu rétablis à l arrêt')
M.setSettings({traffic = {mode = 'keep', police = 'off'}})

print('-- v1.3 : boîte automatique / manuelle')
-- oldie n'indique pas sa boîte : déduite de ses pièces (fichier .pc), seulement quand le filtre sert
env.files['/vehicles/oldie/base.pc'] = {format = 2, parts = {oldie_engine = 'oldie_engine_v8', oldie_transmission = 'oldie_transmission_4M'}}
M.setSettings({veh = {transmission = 'manual', cats = {citadine = true, berline = true, familiale = true, coupe = true, sport = true, suv = true, pickup = true, utilitaire = true, camion = false, bus = false, toutterrain = false, engin = false, autre = true}}})
M.requestVehicles()
local tv = state().vehicles
check(tv.eligibleConfigs == 2, 'manuelle : sedanx sport + oldie (boîte lue dans ses pièces)', tv.eligibleConfigs)
M.setSettings({veh = {transmission = 'auto'}})
check(state().vehicles.eligibleConfigs == 1, 'automatique : sedanx base seulement', state().vehicles.eligibleConfigs)
M.setSettings({veh = {transmission = 'manual'}})
M.start()
frames(400)
local tvi = sess() and sess().vehicle
check(tvi and (tvi.model == 'oldie' or tvi.name:find('sport')) and tvi.trans == 'Manuelle', 'livraison avec une boîte manuelle', tvi and (tvi.name .. ' / ' .. tostring(tvi.trans)))
M.stop()
check(lastRec().transmission == 'Manuelle', 'boîte notée dans le journal', lastRec().transmission)
M.setSettings({veh = {transmission = 'both'}})
check(state().vehicles.eligibleConfigs >= 3, 'les deux : tout revient', state().vehicles.eligibleConfigs)

print('-- v1.3.1 : percuter une voiture de police = 1 étoile')
M.setSettings({traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
check(sess() and sess().phase == 'driving', 'en route (choc police)')
local me = getPlayerVehicle(0).id
local hitCop = env.newVeh('sedanx', '/vehicles/sedanx/police.pc', vec3(-2000, -2000, 10))
local touch = {inArea = true, speed = 0.4, dot = 0.9}       -- simple frôlement à l'arrêt : rien
local theirFault = {inArea = true, speed = 6, dot = -0.8}   -- la police nous rentre dedans : rien
env.traffic.data = {
  [me] = {isAi = false, pursuit = {mode = 0, score = 0}, collisions = {[hitCop.id] = touch}},
  [hitCop.id] = {isAi = true, roleName = 'police', role = {name = 'police', flags = {cooldown = 1}}},
}
env.lastPursuitReset = nil
frames(5)
check(env.lastPursuitReset == nil, 'frôlement à l arrêt : pas d étoile')
env.traffic.data[me].collisions = {[hitCop.id] = theirFault}
frames(5)
check(env.lastPursuitReset == nil, 'la police nous percute : pas d étoile')
local myFault = {inArea = true, speed = 7, dot = 0.85}
env.traffic.data[me].collisions = {[hitCop.id] = myFault}
frames(5)
check(env.lastPursuitReset and env.lastPursuitReset.mode == 1 and env.lastPursuitReset.vid == me, 'je percute la police : poursuite niveau 1 (1 étoile)')
check(myFault.offense == true, 'pas de double pénalité du jeu pour le même choc')
check(env.events.LivraisonLibreToast and env.events.LivraisonLibreToast.msg:find('percuté la police'), 'message dans l app')
env.lastPursuitReset = nil
frames(5)
check(env.lastPursuitReset == nil, 'un seul déclenchement par choc')
env.traffic.data[me].pursuit.mode = 2
env.traffic.data[me].collisions = {[hitCop.id] = {inArea = true, speed = 9, dot = 0.9}}
frames(5)
check(env.lastPursuitReset == nil, 'déjà recherché : le jeu gère la suite')
env.traffic.data = {}
hitCop:delete()
M.stop()

print('-- v1.4 : points d intérêt masqués pendant les livraisons')
gameplay_playmodeMarkers = {validPlaymodeMarkersStates = {freeroam = true, career = true}, clear = function() env.poiCleared = (env.poiCleared or 0) + 1 end}
M.setSettings({hidePoi = true, traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
check(sess() and next(gameplay_playmodeMarkers.validPlaymodeMarkersStates) == nil and env.poiCleared == 1, 'points d intérêt masqués pendant la livraison')
M.skip(); frames(400)
check(next(gameplay_playmodeMarkers.validPlaymodeMarkersStates) == nil, 'toujours masqués à la livraison suivante')
M.stop()
check(gameplay_playmodeMarkers.validPlaymodeMarkersStates.freeroam == true and gameplay_playmodeMarkers.validPlaymodeMarkersStates.career == true, 'rétablis à l arrêt')
M.setSettings({hidePoi = false})
M.start(); frames(400)
check(gameplay_playmodeMarkers.validPlaymodeMarkersStates.freeroam == true, 'option désactivée : rien ne change')
M.stop()
M.setSettings({hidePoi = true})
gameplay_playmodeMarkers = nil

print('-- v1.5 : police réglée pendant la livraison')
M.setSettings({traffic = {mode = 'on', police = 'patrol', amount = 8, strictness = 0.5, npcChases = true}, timeLimit = false, autoNext = true, instantNext = false})
M.start()
frames(400)
check(sess() and sess().phase == 'driving', 'en route (police en livraison)')
check(sess().police and sess().police.mode == 'patrol', 'réglage de police proposé pendant la livraison', sess().police and sess().police.mode)
check(env.policeVars.suspectFrequency == 0.5, 'poursuites de PNJ actives par défaut')
local pv = getPlayerVehicle(0).id
M.setMissionPolice('off')
check(sess().police.mode == 'off' and env.policeVars.strictness == 0, 'police coupée : plus aucune infraction relevée')
check(env.lastPursuitReset and env.lastPursuitReset.mode == 0 and env.lastPursuitReset.vid == pv, 'poursuite en cours arrêtée')
check(env.files['/settings/livraisonLibre/settings.json'].traffic.police == 'off', 'choix gardé pour les livraisons suivantes')
-- choc avec la police alors qu'elle est coupée : pas d'étoile
local cop2 = env.newVeh('sedanx', '/vehicles/sedanx/police.pc', vec3(-2000, -2000, 10))
env.traffic.data = {
  [pv] = {isAi = false, pursuit = {mode = 0, score = 0}, collisions = {[cop2.id] = {inArea = true, speed = 8, dot = 0.9}}},
  [cop2.id] = {isAi = true, roleName = 'police', role = {name = 'police', flags = {}}},
}
env.lastPursuitReset = nil
frames(5)
check(env.lastPursuitReset == nil, 'police coupée : un choc ne donne pas d étoile')
env.traffic.data = {}
cop2:delete()
env.wantedVeh = nil
M.setMissionPolice('wanted', 4)
check(sess().police.mode == 'wanted' and sess().police.level == 4, 'passage en recherché, 4 étoiles', sess().police.level)
check(env.policeVars.strictness == 0.5, 'sévérité normale rétablie')
check(env.wantedVeh == pv and env.wantedLevel == 2, 'poursuite lancée tout de suite au bon niveau du jeu', env.wantedLevel)
M.setMissionPolice('wanted', 5)
check(env.wantedLevel == 3 and env.files['/settings/livraisonLibre/settings.json'].traffic.wantedLevel == 5, 'niveau changé à chaud (5 étoiles)')
M.setMissionPolice('patrol')
check(sess().police.mode == 'patrol' and env.lastPursuitReset.mode == 0, 'retour en patrouilles : poursuite remise à zéro')
M.setMissionPolice('off')
M.stop()
check(env.policeVars.strictness == 0.5, 'sévérité d origine rendue au jeu à l arrêt', env.policeVars.strictness)

print('-- v1.5 : poursuites de PNJ désactivables')
M.setSettings({traffic = {police = 'patrol', npcChases = false}})
M.start()
frames(400)
check(env.policeVars.suspectFrequency == 0, 'plus de PNJ poursuivis par la police', env.policeVars.suspectFrequency)
M.stop()
M.setSettings({traffic = {npcChases = true}})

print('-- v1.5 : temps restant (temps limite)')
M.setSettings({timeLimit = true, avgSpeedKmh = 45, timeBonus = 60, minDist = 600, autoNext = false, instantNext = false, traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
check(sess() and sess().phase == 'driving', 'en route (temps limite)')
check(type(hud().timeLeft) == 'number' and hud().timeLeft > 0 and hud().phase == 'driving', 'compte à rebours envoyé pendant la livraison', hud().timeLeft)
drive(300, 15)
deliverNow()
frames(10)
local sumEv = env.events.LivraisonLibreSummary
check(sumEv and sumEv.ok and type(sumEv.timeLeft) == 'number' and sumEv.timeLeft > 0, 'temps restant dans le résumé', sumEv and sumEv.timeLeft)
check(sess().summary and sess().summary.timeLeft == sumEv.timeLeft, 'temps restant dans le bloc du panneau')
check(type(lastRec().timeLeftS) == 'number' and lastRec().timeLeftS > 0, 'temps restant dans le journal', lastRec().timeLeftS)
M.stop()
M.setSettings({timeLimit = false, minDist = 300, autoNext = true})

print('-- v1.6 : temps limite selon la difficulté')
-- (jusqu'à Difficile : à partir de Très difficile le temps compte aussi le stationnement)
local limits = {}
for _, lvl in ipairs({'tres_facile', 'moyen', 'dur'}) do
  M.setSettings({timeLimit = true, timeLevel = lvl, minDist = 600, autoNext = false, instantNext = false, traffic = {mode = 'keep', police = 'off'}})
  M.onClientPostStartMission('/levels/testcity/main.level.json') -- map rechargée : lieux récents oubliés, même livraison
  math.randomseed(4242)
  M.start()
  frames(400)
  limits[lvl] = sess() and sess().timeLimit
  check(sess() and sess().timeLevel and type(limits[lvl]) == 'number' and limits[lvl] >= 20, 'temps limite calculé (' .. lvl .. ')', limits[lvl])
  if lvl == 'moyen' then
    check(sess().timeLevel == 'Moyen', 'niveau affiché pendant la livraison', sess().timeLevel)
    drive(200, 12)
    deliverNow()
    frames(5)
    check(env.events.LivraisonLibreSummary.timeLevel == 'Moyen', 'niveau dans le résumé')
    check(lastRec().timeLevel == 'Moyen', 'niveau dans le journal', lastRec().timeLevel)
  end
  M.stop()
end
check(limits.tres_facile > limits.moyen and limits.moyen > limits.dur, 'même livraison : moins de temps quand la difficulté monte',
  string.format('%.0f / %.0f / %.0f s', limits.tres_facile or -1, limits.moyen or -1, limits.dur or -1))
M.setSettings({timeLimit = false, timeLevel = 'moyen', autoNext = true})

print('-- v1.7 : difficulté modifiable tant que le chrono n est pas lancé')
M.setSettings({timeLimit = true, timeLevel = 'moyen', minDist = 600, autoNext = false, instantNext = false, traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
check(sess() and sess().phase == 'driving' and sess().timeLevelId == 'moyen', 'livraison avec temps limite (moyen)')
check(hud().chronoState == 'wait', 'chrono pas encore lancé')
local tMoyen = sess().timeLimit
M.setMissionTimeLevel('impossible')
local tImp = sess().timeLimit
check(sess().timeLevelId == 'impossible' and sess().timeLevel == 'Impossible' and tImp < tMoyen, 'avant le départ : difficulté changée et temps recalculé',
  string.format('%.0f -> %.0f s', tMoyen, tImp))
M.setMissionTimeLevel('tres_facile')
check(sess().timeLimit > tMoyen, 'plus facile : plus de temps')
M.setMissionTimeLevel('n_importe_quoi')
check(sess().timeLevelId == 'tres_facile', 'niveau inconnu ignoré')
-- autre véhicule avant le départ : le temps suit le nouveau véhicule (pas celui d'avant)
local followsVeh, seen, nSeen = true, {}, 0
for _ = 1, 6 do
  M.rerollVehicle()
  frames(40)
  local kept = sess().timeLimit
  M.setMissionTimeLevel('tres_facile')
  if math.abs(sess().timeLimit - kept) > 1e-6 then followsVeh = false end
  local key = string.format('%.3f', kept)
  if not seen[key] then seen[key] = true; nSeen = nSeen + 1 end
end
check(sess().phase == 'driving' and hud().chronoState == 'wait' and followsVeh and nSeen > 1,
  'autre véhicule avant le départ : temps recalculé pour ce véhicule', nSeen .. ' temps différents')
-- on démarre : le chrono se lance, le choix n'est plus possible
local v = getPlayerVehicle(0)
v.pos = vec3(-3000, -3000, 10)
v.vel = vec3(15, 0, 0)
frames(60)
v.vel = vec3(0, 0, 0)
check(hud().chronoState ~= 'wait', 'chrono lancé après la 1re accélération', hud().chronoState)
local tLocked = sess().timeLimit
M.setMissionTimeLevel('impossible')
check(sess().timeLimit == tLocked and sess().timeLevelId == 'tres_facile', 'après le départ : temps de la livraison inchangé')
check(env.files['/settings/livraisonLibre/settings.json'].timeLevel == 'impossible', 'mais le choix est gardé pour la suivante')
M.rerollVehicle()
frames(40)
check(sess().timeLimit == tLocked and sess().timeLevelId == 'tres_facile', 'après le départ : autre véhicule, même temps')
M.stop()
M.setSettings({timeLimit = false, timeLevel = 'moyen', minDist = 300, autoNext = true})

print('-- v1.7.1 : chrono jusqu à la validation (très difficile et plus, ou option)')
M.setSettings({timeLimit = true, timeLevel = 'tres_dur', fullChrono = false, minDist = 600, autoNext = false, instantNext = false, validation = 'handbrake', traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
check(sess() and sess().phase == 'driving' and sess().fullChrono == true, 'très difficile : chrono jusqu à la validation')
drive(300, 15)
frames(2)
parkInZone(0)
frames(60)
check(hud().chronoState == 'running', 'le chrono tourne pendant le stationnement', hud().chronoState)
local left1 = hud().timeLeft
frames(120)
check(hud().timeLeft < left1 - 1.5, 'le temps restant baisse pendant le stationnement', string.format('%.1f -> %.1f', left1, hud().timeLeft))
getPlayerVehicle(0).parkbrake = 1
frames(90)
getPlayerVehicle(0).parkbrake = 0
check(sess().phase == 'summary' and lastRec().result == 'Livrée', 'livrée (chrono jusqu à la validation)')
local rec = lastRec()
check(type(rec.timeLeftS) == 'number' and rec.timeS < (rec.timeLimitS - rec.timeLeftS) - 1,
  'journal : temps de trajet sans le stationnement, temps limite avec', string.format('%s / %s - %s', tostring(rec.timeS), tostring(rec.timeLimitS), tostring(rec.timeLeftS)))
M.stop()
M.setSettings({timeLevel = 'moyen'})
M.start()
frames(400)
check(sess().fullChrono == false, 'moyen : chrono arrêté à 50 m de la zone')
drive(300, 15)
frames(2)
parkInZone(0)
frames(60)
check(hud().chronoState == 'stopped', 'moyen : chrono arrêté près de la zone', hud().chronoState)
M.stop()
M.setSettings({fullChrono = true})
M.start()
frames(400)
check(sess().fullChrono == true, 'option avancée : chrono jusqu à la validation aussi en moyen')
drive(300, 15)
frames(2)
parkInZone(0)
frames(60)
check(hud().chronoState == 'running', 'option : le chrono tourne pendant le stationnement', hud().chronoState)
M.stop()
check(env.files['/settings/livraisonLibre/settings.json'].fullChrono == true, 'option gardée dans les réglages')
M.setSettings({timeLimit = false, fullChrono = false, timeLevel = 'moyen', minDist = 300, autoNext = true})

print('-- v1.7.1 : demi-tour avant le départ')
M.setSettings({timeLimit = false, autoNext = false, instantNext = false, traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
local fv = getPlayerVehicle(0)
local d0 = vec3(fv.dir)
local r0 = hud().resets
M.flipVehicle()
frames(5)
local dd = fv.dir.x * d0.x + fv.dir.y * d0.y + fv.dir.z * d0.z
check(dd < -0.99, 'demi-tour : véhicule tourné dans l autre sens', dd)
check(hud().chronoState == 'wait' and hud().resets == r0, 'demi-tour : ni départ du chrono, ni remise en place comptée')
-- une fois parti : plus de demi-tour
fv.pos = vec3(-3000, -3000, 10)
fv.vel = vec3(15, 0, 0)
frames(60)
fv.vel = vec3(0, 0, 0)
local d1 = vec3(fv.dir)
M.flipVehicle()
frames(5)
check(hud().chronoState ~= 'wait' and fv.dir.x * d1.x + fv.dir.y * d1.y > 0.99, 'après le départ : plus de demi-tour')
M.stop()
M.setSettings({autoNext = true})

print('-- v1.7.1 : frein à main serré à 15 % : validé')
M.setSettings({timeLimit = false, autoNext = false, instantNext = false, validation = 'handbrake', traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
drive(300, 15)
frames(2)
parkInZone(0)
getPlayerVehicle(0).parkbrake = 0.1
frames(90)
check(sess().phase == 'driving', 'frein à main à 10 % : pas encore validé')
getPlayerVehicle(0).parkbrake = 0.15
frames(90)
getPlayerVehicle(0).parkbrake = 0
check(sess().phase == 'summary', 'frein à main à 15 % : livraison validée', sess().phase)
M.stop()
M.setSettings({autoNext = true})

print('-- v1.7.2 : départs variés (lieux récents évités)')
M.setSettings({timeLimit = false, autoNext = false, instantNext = false, minDist = 300, maxDist = 900, traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
local starts = {}
for _ = 1, 6 do
  local v0 = getPlayerVehicle(0)
  starts[#starts + 1] = vec3(v0.pos)
  M.skip()
  -- attendre le nouveau véhicule (fondu, chargement) avant de relever sa position
  for _ = 1, 1500 do
    frames(1)
    local v = getPlayerVehicle(0)
    if v and v.id ~= v0.id and sess() and sess().phase == 'driving' then break end
  end
end
local close, detail = 0, nil
for i = 1, #starts do
  for j = i + 1, #starts do
    local d = (starts[i] - starts[j]):length()
    if d < 100 then close = close + 1; detail = detail or string.format('%d et %d à %.0f m', i, j, d) end
  end
end
check(close == 0 and sess() ~= nil, 'départs variés : 6 livraisons, jamais deux fois au même endroit', detail)
M.stop()
M.setSettings({autoNext = true})

print('-- v1.7.4 : place dégagée à l arrivée (trafic à moins de 50 m)')
-- (sans « Écarter la police près de l'arrivée », pour vérifier qu'on laisse la police qui poursuit)
M.setSettings({timeLimit = false, autoNext = false, instantNext = false, traffic = {mode = 'keep', police = 'off', clearNearSpot = true, clearPoliceNearEnd = false}})
M.start()
frames(400)
local z1 = env.lastZone
local onSpot = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(z1.x, z1.y, z1.z))
local passing = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(z1.x + 35, z1.y, z1.z))
local farCar = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(z1.x + 120, z1.y, z1.z))
local chaser = env.newVeh('sedanx', '/vehicles/sedanx/police.pc', vec3(z1.x + 20, z1.y, z1.z))
local me = getPlayerVehicle(0)
env.traffic.data = {
  [onSpot.id] = {isAi = true, roleName = 'standard', speed = 0},
  [passing.id] = {isAi = true, roleName = 'standard', speed = 12},
  [farCar.id] = {isAi = true, roleName = 'standard', speed = 12},
  [chaser.id] = {isAi = true, roleName = 'police', role = {name = 'police', flags = {pursuit = true}, targetId = me.id}},
}
env.traffic.teleported = {}
me.pos = vec3(z1.x + 200, z1.y, z1.z)
frames(60)
local early = {}
for _, t in ipairs(env.traffic.teleported) do early[t.id] = true end
check(not early[passing.id], 'loin de la place : le trafic qui passe n est pas touché')
me.pos = vec3(z1.x + 40, z1.y, z1.z)
frames(60)
local moved = {}
for _, t in ipairs(env.traffic.teleported) do moved[t.id] = true end
check(moved[passing.id] and not moved[farCar.id] and not moved[chaser.id],
  'à moins de 50 m : le trafic autour de la place est envoyé plus loin (pas la police qui poursuit, pas les voitures loin)')
check(moved[onSpot.id] == true, 'PNJ arrêté sur la place : dégagé')
env.traffic.data = {}
onSpot:delete(); passing:delete(); farCar:delete(); chaser:delete()
M.stop()
-- option coupée : on ne touche à rien
M.setSettings({traffic = {clearNearSpot = false}})
M.start()
frames(400)
local z2 = env.lastZone
local p2 = env.newVeh('oldie', '/vehicles/oldie/base.pc', vec3(z2.x + 30, z2.y, z2.z))
env.traffic.data = {[p2.id] = {isAi = true, roleName = 'standard', speed = 12}}
env.traffic.teleported = {}
getPlayerVehicle(0).pos = vec3(z2.x + 40, z2.y, z2.z)
frames(60)
check(#env.traffic.teleported == 0, 'option coupée : le trafic près de la place n est pas touché')
env.traffic.data = {}
p2:delete()
M.stop()
M.setSettings({autoNext = true, traffic = {clearNearSpot = true, clearPoliceNearEnd = true}})

print('-- v1.7.6 : temps limite calculé sur le trajet du GPS')
M.setSettings({timeLimit = true, timeLevel = 'dur', minDist = 600, autoNext = false, instantNext = false, traffic = {mode = 'keep', police = 'off'}})
M.start()
frames(400)
check(sess() and sess().phase == 'driving' and hud().chronoState == 'wait', 'livraison prête (chrono pas lancé)')
local zg = env.lastZone
local tMod = sess().timeLimit
-- deux tracés du GPS vers la place : direct, et avec un grand détour
local function gridPath(cols)
  local p = {{pos = {x = getPlayerVehicle(0).pos.x, y = getPlayerVehicle(0).pos.y, z = 10}}}
  for _, c in ipairs(cols) do
    local id = 'g' .. c[1] .. '_' .. c[2]
    local n = env.nodes[id]
    p[#p + 1] = {pos = {x = n.pos.x, y = n.pos.y, z = n.pos.z}, wp = id}
  end
  p[#p + 1] = {pos = {x = zg.x, y = zg.y, z = zg.z}}
  return p
end
local zi, zj = math.floor(zg.x / 120 + 0.5), math.floor(zg.y / 120 + 0.5)
local direct, detour = {}, {}
-- (toujours au moins 5 points : depuis le bord de la ville le plus éloigné de la place)
if zi >= 4 then for i = 0, zi do direct[#direct + 1] = {i, zj} end else for i = 8, zi, -1 do direct[#direct + 1] = {i, zj} end end
for j = 0, 8 do detour[#detour + 1] = {0, j} end
for i = 1, 8 do detour[#detour + 1] = {i, 8} end
for j = 7, zj, -1 do detour[#detour + 1] = {8, j} end
for i = 7, zi, -1 do detour[#detour + 1] = {i, zj} end
core_groundMarkers.routePlanner = {path = gridPath(direct)}
M.setMissionTimeLevel('dur')
local tDirect = sess().timeLimit
core_groundMarkers.routePlanner = {path = gridPath(detour)}
M.setMissionTimeLevel('dur')
local tDetour = sess().timeLimit
check(tDetour > tDirect * 1.3, 'GPS avec un grand détour : plus de temps', string.format('%.0f -> %.0f s (calcul du mod : %.0f s)', tDirect, tDetour, tMod))
-- tracé qui ne mène pas à cette place (ancienne livraison) : ignoré
core_groundMarkers.routePlanner = {path = {{pos = {x = -5000, y = -5000, z = 10}, wp = 'g0_0'}, {pos = {x = -4000, y = -5000, z = 10}, wp = 'g1_0'}}}
M.setMissionTimeLevel('dur')
check(math.abs(sess().timeLimit - tMod) < 0.5, 'tracé du GPS vers une autre place : ignoré, calcul du mod', string.format('%.1f / %.1f', sess().timeLimit, tMod))
-- livraison avec le tracé du GPS : trajet enregistré pour mesurer la précision du temps limite
core_groundMarkers.routePlanner = {path = gridPath(direct)}
M.setMissionTimeLevel('dur')
drive(300, 15)
deliverNow()
frames(10)
local tj = env.files['/settings/livraisonLibre/trajets.json']
local last = tj and tj.routes and tj.routes[#tj.routes]
check(last and #last.wps >= 1 and last.level == 'dur' and last.limit and last.timeS and last.result == 'Livrée' and last.perf ~= nil,
  'trajet de la livraison enregistré (tracé du GPS, niveau, temps donné, temps réel, véhicule)', last and #last.wps)
core_groundMarkers.routePlanner = nil
M.stop()
M.setSettings({timeLimit = false, timeLevel = 'moyen', minDist = 300, autoNext = true})

print('-- relecture complète du mod : corrections')
-- police du jeu : ses réglages sont remis comme avant à l'arrêt, même en « Ne pas toucher »
env.policeVars = {strictness = 0.7, suspectFrequency = 0.5}
M.setSettings({traffic = {mode = 'keep', police = 'off', npcChases = false}, autoNext = false, instantNext = false, timeLimit = false})
M.start()
frames(400)
check(sess() and sess().phase == 'driving' and env.policeVars.suspectFrequency == 0, 'poursuites de PNJ coupées pendant les livraisons')
M.stop()
check(env.policeVars.suspectFrequency == 0.5 and env.policeVars.strictness == 0.7, 'réglages de la police du jeu remis à l arrêt',
  tostring(env.policeVars.suspectFrequency) .. ' / ' .. tostring(env.policeVars.strictness))
M.setSettings({traffic = {npcChases = true}})
env.policeVars = {}

-- arrêt juste après « Autre véhicule » : la livraison en cours est quand même notée au journal
M.start()
frames(400)
drive(400, 15)
local nJ = #journalRecs()
M.rerollVehicle()
frames(5)
check(sess() and sess().phase == 'spawning', 'changement de véhicule en cours', sess() and sess().phase)
M.stop()
check(#journalRecs() == nJ + 1 and lastRec().result == 'Arrêtée', 'arrêt pendant le changement de véhicule : livraison notée « Arrêtée »', #journalRecs() - nJ)

-- « Autre véhicule » qui tombe sur un véhicule impossible à faire apparaître (mod cassé) : on garde le sien
env.models.broken = {Name = 'Broken', Type = 'Car', ['Body Style'] = 'Sedan', Years = {min = 2010, max = 2018}}
table.insert(env.configs, cfg('broken', 'base'))
M.onModActivated()
M.start()
frames(400)
M.onModActivated() -- (si le tout premier tirage est tombé dessus, il a été écarté : on l'oublie pour le test)
local hitBroken, keptVeh = false, nil
for _ = 1, 60 do
  if not sess() then break end
  env.events.LivraisonLibreToast = nil
  local before = sess().vehicle and sess().vehicle.model
  M.rerollVehicle()
  frames(40)
  local t = env.events.LivraisonLibreToast
  if t and tostring(t.msg):find('ne peut pas appara') then hitBroken, keptVeh = true, before break end
end
check(hitBroken and sess() and sess().phase == 'driving' and sess().vehicle.model == keptVeh,
  'véhicule impossible à faire apparaître : la livraison continue avec le véhicule actuel', hitBroken)
local brokenAgain = false
for _ = 1, 20 do
  M.rerollVehicle()
  frames(40)
  if sess() and sess().vehicle and sess().vehicle.model == 'broken' then brokenAgain = true end
end
check(sess() and not brokenAgain, 'ce véhicule n est plus tiré ensuite')
M.stop()
env.models.broken = nil
table.remove(env.configs)
M.onModActivated()

-- recherché : « Nouvelle destination » ne remet pas à zéro une poursuite en cours
M.setSettings({traffic = {mode = 'on', amount = 10, parked = 0, police = 'wanted', wantedLevel = 1, removeOnStop = true}})
M.start()
frames(80)
frames(60 * 3)
local pv2 = getPlayerVehicle(0).id
check(env.wantedVeh == pv2, 'recherché au départ')
env.pursuitMode = 2
env.wantedVeh = nil
M.rerollDestination()
frames(60 * 4)
check(sess().phase == 'driving' and env.wantedVeh == nil, 'nouvelle destination : la poursuite en cours continue (pas relancée)')
-- « Autre véhicule » pendant une poursuite : le nouveau véhicule est toujours recherché
M.rerollVehicle()
env.pursuitMode = 0 -- le jeu remet à zéro le rôle du véhicule remplacé
frames(60 * 4)
check(sess().phase == 'driving' and env.wantedVeh == getPlayerVehicle(0).id, 'autre véhicule : toujours recherché')
M.stop()
env.pursuitMode = 0
env.wantedVeh = nil

-- arrêt pendant le chargement du trafic : il est retiré dès qu'il est prêt
M.setSettings({traffic = {mode = 'on', amount = 10, parked = 0, police = 'patrol', removeOnStop = true}})
M.start()
for _ = 1, 400 do
  if env.trafficReadyIn then break end
  frames(1)
end
check(env.trafficReadyIn ~= nil and sess() and sess().loadingTraffic, 'trafic en cours de chargement')
local d0 = env.traffic.deletes
M.stop()
check(env.traffic.deletes == d0, 'pas de suppression pendant le chargement (le jeu l ignorerait)')
frames(60)
check(env.traffic.deletes == d0 + 1 and env.traffic.amount == 0, 'trafic retiré dès qu il est prêt', env.traffic.amount)
M.setSettings({traffic = {mode = 'keep', police = 'off'}})

-- première livraison après remise à zéro : pas de « nouveau record »
M.resetStats()
M.setSettings({autoNext = false, instantNext = false})
M.start()
frames(400)
drive(800, 20)
deliverNow()
frames(10)
check(sess().phase == 'summary' and not sess().summary.record, 'toute première livraison : pas annoncée comme record')
M.stop()

-- validation éclair : une livraison ratée enchaîne aussi
M.setSettings({timeLimit = true, timeLevel = 'impossible', autoNext = false, instantNext = true, validation = 'handbrake'})
M.start()
frames(400)
local sawFail, chained = false, false
local vf = getPlayerVehicle(0)
vf.pos = vec3(-3000, -3000, 10)
vf.vel = vec3(30, 0, 0)
for _ = 1, 60 * 150 do
  frames(1)
  local ph = sess() and sess().phase
  if ph == 'failed' then sawFail = true; getPlayerVehicle(0).vel = vec3(0, 0, 0) end
  if sawFail and ph and ph ~= 'failed' then chained = true break end
end
check(sawFail and chained, 'livraison ratée : la suivante démarre aussi (validation éclair)', tostring(sawFail) .. ' / ' .. tostring(chained))
M.stop()
M.setSettings({timeLimit = false, timeLevel = 'moyen', autoNext = true, instantNext = false, validation = 'auto'})

print('-- analyse de la map en échec : message clair, pas d exception, pas de spam')
M.onClientPostStartMission('/levels/testcity/main.level.json')
local realGetMap = map.getMap
map.getMap = function() error('panne simulée') end
local okCall = pcall(M.requestMapInfo)
check(okCall, 'erreur interceptée (pas d exception vers le jeu)')
check(env.events.LivraisonLibreToast and env.events.LivraisonLibreToast.msg:find('Analyse de la map impossible'), 'message d analyse dans l app',
  env.events.LivraisonLibreToast and env.events.LivraisonLibreToast.msg)
for i = 1, 10 do pcall(M.requestMapInfo) end
local nE = 0
for _, l in ipairs(env.logs) do if l.level == 'E' and tostring(l.msg):find('panne simulée') then nE = nE + 1 end end
check(nE == 3, 'pas de spam dans la console (3 max)', nE)
map.getMap = realGetMap

print('-- garde-fou : une erreur interne ne remonte pas au jeu')
local realWrite = jsonWriteFile
jsonWriteFile = function() error('panne simulée 2') end
okCall = pcall(M.setSettings, {minDist = 700})
check(okCall, 'erreur interceptée par le garde-fou')
check(env.events.LivraisonLibreToast and env.events.LivraisonLibreToast.msg:find('erreur interne'), 'petit message dans l app')
nE = 0
for _, l in ipairs(env.logs) do if l.level == 'E' and tostring(l.msg):find('panne simulée 2') then nE = nE + 1 end end
check(nE == 1, 'erreur écrite une fois dans la console avec la pile', nE)
for i = 1, 10 do pcall(M.setSettings, {minDist = 700}) end
nE = 0
for _, l in ipairs(env.logs) do if l.level == 'E' and tostring(l.msg):find('panne simulée 2') then nE = nE + 1 end end
check(nE == 3, 'garde-fou : pas de spam dans la console (3 max)', nE)
jsonWriteFile = realWrite
print(string.format('SIM TESTS: %d passed, %d failed', passed, failed))
assert(failed == 0, 'tests failed')
