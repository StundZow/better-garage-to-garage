-- Livraison Libre - livraison de véhicules en freeroam (style "garage to garage", personnalisable)
-- Extension GE : choix du véhicule et des lieux, téléport, GPS, zone "P" au sol, validation
-- au frein à main, trafic / police, chrono / temps limite, statistiques, journal de toutes
-- les livraisons (CSV) et points de livraison perso.

local M = {}
local logTag = 'livraisonLibre'

local graphLib = require('/lua/ge/extensions/livraisonLibre/graph')
local locLib = require('/lua/ge/extensions/livraisonLibre/locations')
local vehLib = require('/lua/ge/extensions/livraisonLibre/vehicles')
local trafficCtl = require('/lua/ge/extensions/livraisonLibre/trafficCtl')
local journal = require('/lua/ge/extensions/livraisonLibre/journal')

local VERSION = '1.3.2'
local DATA_DIR = '/settings/livraisonLibre/'
local SETTINGS_FILE = DATA_DIR .. 'settings.json'
local STATS_FILE = DATA_DIR .. 'stats.json'
local POINTS_DIR = DATA_DIR .. 'points/'
local JOURNAL_FILE = DATA_DIR .. 'livraisons.json'
local JOURNAL_CSV = DATA_DIR .. 'livraisons.csv'
local DECAL_TEXTURE = 'art/shapes/interface/parkDecalStripes.png'
local HISTORY_MAX = 25
local SWITCH_MIN_DIST = 500      -- en dessous, un véhicule abandonné n'est pas noté dans le journal
local PERF_START_SPEED = 1.5     -- m/s : le chrono du trajet démarre à la première accélération
local PERF_END_DIST = 50         -- m : il s'arrête à 50 m de la zone (le stationnement ne fausse pas la perf)
local CENTER_POST_HEIGHT = 2     -- m : trait vertical au centre de la place de livraison
local SPEED_WINDOW = 8           -- échantillons pour lisser la vitesse (pics parasites)
local MAX_PLAUSIBLE_SPEED = 140  -- m/s (~500 km/h) : au-delà, la mesure est ignorée
local SUMMARY_DELAY = 0.9        -- s : délai après la fin du fondu avant d'afficher le résumé
local POLICE_CLEAR_DIST = 100    -- m : police écartée en approche de la zone
local ANALYSIS_BUDGET = 0.006    -- s de calcul par image pour l'analyse de la map (le jeu ne fige jamais)
local ANALYSIS_TIMEOUT = 45      -- s : au-delà, l'analyse est abandonnée avec un message
local ANALYSIS_FILE = DATA_DIR .. 'analyse.txt' -- étapes de la dernière analyse (diagnostic)
local FFB_RELEASE_DELAY = 1.5    -- s après le retour de l'image avant de rendre le retour de force

local abs, min, max, sqrt, floor = math.abs, math.min, math.max, math.sqrt, math.floor

local DEFAULTS = {
  version = 2,
  locMode = 'random',            -- 'random' | 'custom'
  locKinds = {road = true, parking = true, poi = true, home = true},
  surface = 'paved',             -- 'paved' | 'any'
  minDist = 600,                 -- mètres (distance routière)
  maxDist = 3500,
  avoidHighways = true,
  pavedThreshold = 0.7,          -- "drivability" minimale considérée comme bitume
  zoneScale = 1.3,               -- zone = 1.3x la taille du véhicule
  validation = 'handbrake',      -- 'handbrake' | 'auto'
  firstStartHere = false,        -- 1re mission depuis ma position (sinon téléport)
  keepOwnVehicle = false,        -- garder mon véhicule de départ
  fade = true,
  timeLimit = false,
  avgSpeedKmh = 45,
  timeBonus = 60,
  randomPaint = true,
  autoNext = true,
  instantNext = false,           -- validation éclair : 0,25 s après le frein à main, livraison suivante directe
  summaryDuration = 5,           -- s : durée d'affichage de l'écran de résumé (3 à 15)
  showCenterPost = true,         -- trait vertical de 2 m au centre de la place
  showBeam = true,               -- colonne lumineuse visible de loin
  showArrow = true,              -- flèche flottante au-dessus de la zone
  ffbGuard = true,               -- coupe le retour de force du volant pendant les chargements
  veh = {
    cats = {citadine = true, berline = true, familiale = true, coupe = true, sport = true, suv = true,
            pickup = true, utilitaire = true, camion = false, bus = false, toutterrain = false, engin = false, autre = true},
    epochs = {ancienne = true, retro = true, moderne = true, inconnue = true},
    variants = {usine = true, custom = true, course = false, police = false, service = false},
    sources = {officiel = true, mod = true, perso = false},
    transmission = 'both',       -- 'both' | 'auto' | 'manual'
    blacklist = {},
  },
  traffic = {
    mode = 'keep',               -- 'keep' (ne rien changer) | 'off' (sans trafic) | 'on' (trafic du mod)
    amount = 8,                  -- véhicules en circulation
    parked = 6,                  -- voitures garées
    police = 'off',              -- 'off' | 'patrol' | 'wanted'
    strictness = 0.5,            -- sévérité de la police
    wantedLevel = 1,             -- étoiles de départ en mode recherché (1 à 5)
    policeRatio = 0.25,          -- part de voitures de police dans le trafic
    civiliansIgnoreSirens = true,-- pendant les livraisons, les PNJ ne se rangent plus pour les sirènes
    policeNoSiren = false,       -- secours : police sans gyrophares ni sirènes
    clearPoliceNearEnd = true,   -- à moins de 100 m de l'arrivée : police écartée, poursuite terminée
    progressive = true,          -- difficulté qui monte avec les étoiles (agressivité, barrages, renforts, police lourde)
    arrestFails = true,          -- une arrestation fait rater la livraison
    removeOnStop = true,         -- retire le trafic du mod à l'arrêt des livraisons
  },
  ui = {tab = 'options', collapsed = false},
}

local STATS_DEFAULTS = {
  delivered = 0, failed = 0, skipped = 0,
  distance = 0, time = 0,
  bestAvg = 0, fastest = nil, longest = 0,
  streak = 0, bestStreak = 0,
  history = {},
}

local KIND_LABEL = {road = 'Bord de route', parking = 'Parking', poi = "Lieu d'intérêt", home = 'Résidence', custom = 'Point perso'}
local CAT_LABEL = {
  citadine = 'Citadine', berline = 'Berline', familiale = 'Break / monospace', coupe = 'Coupé / cabriolet',
  sport = 'Sportive', suv = 'SUV / 4x4', pickup = 'Pick-up', utilitaire = 'Utilitaire', camion = 'Camion',
  bus = 'Bus', toutterrain = 'Tout-terrain', engin = 'Engin', autre = 'Autre',
}
local POLICE_LABEL = {off = 'Aucune', patrol = 'Patrouilles', wanted = 'Recherché'}
local TRANS_LABEL = {auto = 'Automatique', manual = 'Manuelle'}
local UI_TABS = {options = true, lieux = true, vehicules = true, trafic = true, points = true, stats = true, parametres = true}

local REASONS = {
  need_points = "Mode « Mes points » : enregistre au moins 2 points de livraison sur cette map (onglet Points).",
  no_candidates = "Aucun lieu compatible sur cette map avec ces réglages (types de lieux, bitume, taille du véhicule).",
  no_destination = "Aucune destination trouvée à cette distance. Élargis la distance min / max.",
}

local settings, stats
local journalRecords, journalSeq = {}, 0
local levelData = nil
local pointsCache = {}
local vehPool = nil
local badModels = {}     -- modèles impossibles à spawner (mods cassés), oubliés au rechargement des mods
local S = nil            -- session de livraison en cours
local hudTimer = 0
local marker, markerSeq = nil, 0
local decalTbl, decalPos, decalFwd, decalScale
local colRed, colBlue, colGreen
local reservedList = {}  -- places de parking réservées pour la livraison en cours
local writeErrorShown = false
local analysis = nil     -- analyse de la map en cours (coroutine étalée sur plusieurs images)
local startPending = false
local analysisErrors = 0
local ffbHeld = {}       -- véhicules dont le retour de force est coupé pendant un chargement

---------------------------------------------------------------------------
-- utilitaires
---------------------------------------------------------------------------
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

local function ensureExt(name)
  if not _G[name] and extensions and extensions.load then pcall(extensions.load, name) end
  return _G[name]
end

local function fmtTime(s)
  s = max(0, floor((s or 0) + 0.5))
  local h, m, sec = floor(s / 3600), floor((s % 3600) / 60), s % 60
  if h > 0 then return string.format('%d:%02d:%02d', h, m, sec) end
  return string.format('%d:%02d', m, sec)
end

local function fmtDist(m)
  m = m or 0
  if m >= 1000 then return string.format('%.1f km', m / 1000) end
  return string.format('%d m', floor(m + 0.5))
end

local function copyTable(t)
  if type(t) ~= 'table' then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copyTable(v) end
  return o
end

-- Fusionne src dans dst en suivant le gabarit (types respectés).
local function mergeInto(dst, src, tpl)
  if type(src) ~= 'table' then return dst end
  for k, tv in pairs(tpl) do
    local sv = src[k]
    if sv ~= nil then
      if k == 'blacklist' then
        if type(sv) == 'table' then
          local bl = {}
          for mk, on in pairs(sv) do if on == true and type(mk) == 'string' then bl[mk] = true end end
          dst[k] = bl
        end
      elseif type(tv) == 'table' then
        if type(dst[k]) ~= 'table' then dst[k] = copyTable(tv) end
        mergeInto(dst[k], sv, tv)
      elseif type(sv) == type(tv) then
        dst[k] = sv
      end
    end
  end
  return dst
end

local function oneOf(v, allowed, default)
  for _, a in ipairs(allowed) do if v == a then return v end end
  return default
end

local function sanitizeSettings(s)
  s.minDist = clamp(tonumber(s.minDist) or DEFAULTS.minDist, 100, 50000)
  s.maxDist = clamp(tonumber(s.maxDist) or DEFAULTS.maxDist, 200, 60000)
  if s.maxDist < s.minDist + 100 then s.maxDist = s.minDist + 100 end
  s.zoneScale = clamp(tonumber(s.zoneScale) or 1.3, 1.05, 2.5)
  s.pavedThreshold = clamp(tonumber(s.pavedThreshold) or 0.7, 0.05, 1)
  s.avgSpeedKmh = clamp(tonumber(s.avgSpeedKmh) or 45, 10, 250)
  s.timeBonus = clamp(tonumber(s.timeBonus) or 60, 0, 900)
  s.validation = oneOf(s.validation, {'handbrake', 'auto'}, 'handbrake')
  s.locMode = oneOf(s.locMode, {'random', 'custom'}, 'random')
  s.surface = oneOf(s.surface, {'paved', 'any'}, 'paved')
  local t = s.traffic
  t.mode = oneOf(t.mode, {'keep', 'off', 'on'}, 'keep')
  t.police = oneOf(t.police, {'off', 'patrol', 'wanted'}, 'off')
  t.amount = floor(clamp(tonumber(t.amount) or 8, 1, 40) + 0.5)
  t.parked = floor(clamp(tonumber(t.parked) or 6, 0, 40) + 0.5)
  t.strictness = clamp(tonumber(t.strictness) or 0.5, 0.05, 1)
  t.wantedLevel = floor(clamp(tonumber(t.wantedLevel) or 1, 1, 5) + 0.5)
  t.policeRatio = clamp(tonumber(t.policeRatio) or 0.25, 0.05, 0.75)
  s.veh.transmission = oneOf(s.veh.transmission, {'both', 'auto', 'manual'}, 'both')
  s.summaryDuration = floor(clamp(tonumber(s.summaryDuration) or 5, 3, 15) + 0.5)
  if not UI_TABS[s.ui.tab] then s.ui.tab = 'options' end
  s.version = DEFAULTS.version
  return s
end

local function ensureDir(dir)
  pcall(function()
    if FS and not FS:directoryExists(dir) then FS:directoryCreate(dir) end
  end)
end

local function warnWrite(path)
  log('E', logTag, 'Écriture impossible : ' .. path)
  if not writeErrorShown then
    writeErrorShown = true
    guihooks.trigger('LivraisonLibreToast', {kind = 'err', msg = 'Impossible d\'enregistrer ' .. path .. ' (fichier ouvert ailleurs ?)'})
  end
end

-- Écriture JSON sûre : fichier temporaire puis renommage, avec repli en écriture directe
local function writeJson(path, data)
  ensureDir(DATA_DIR)
  local ok = jsonWriteFile(path, data, true, nil, true)
  if not ok then ok = jsonWriteFile(path, data, true) end
  if not ok then warnWrite(path) end
  return ok
end

local function saveSettings() writeJson(SETTINGS_FILE, settings) end
local function saveStats() writeJson(STATS_FILE, stats) end

local function writeText(path, text)
  local ok = false
  if writeFile then
    ok = writeFile(path, text) and true or false
  else
    local f = io.open(path, 'w')
    if f then f:write(text); f:close(); ok = true end
  end
  if not ok then warnWrite(path) end
  return ok
end

local function saveJournal()
  writeJson(JOURNAL_FILE, {version = 1, records = journalRecords})
  writeText(JOURNAL_CSV, journal.toCsv(journalRecords))
end

local function loadData()
  settings = copyTable(DEFAULTS)
  local saved = jsonReadFile(SETTINGS_FILE)
  if type(saved) == 'table' then mergeInto(settings, saved, DEFAULTS) end
  sanitizeSettings(settings)

  stats = copyTable(STATS_DEFAULTS)
  local savedStats = jsonReadFile(STATS_FILE)
  if type(savedStats) == 'table' then
    for k, v in pairs(savedStats) do stats[k] = v end
    if type(stats.history) ~= 'table' then stats.history = {} end
  end

  journalRecords, journalSeq = {}, 0
  local j = jsonReadFile(JOURNAL_FILE)
  if type(j) == 'table' and type(j.records) == 'table' then
    for _, r in ipairs(j.records) do
      if type(r) == 'table' then
        journalRecords[#journalRecords + 1] = r
        journalSeq = max(journalSeq, tonumber(r.id) or 0)
      end
    end
  end
end

local function toast(kind, msg, ttl)
  guihooks.trigger('LivraisonLibreToast', {kind = kind or 'info', msg = msg})
  if ui_message then ui_message(msg, ttl or 5, 'livraisonLibre', kind == 'err' and 'warning' or 'info') end
end

local function levelName()
  local lvl = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  if lvl == '' then lvl = nil end
  return lvl
end

local function playerPos()
  local veh = getPlayerVehicle(0)
  if veh then
    local p = veh:getPosition()
    return p.x, p.y, p.z, veh
  end
  local p = core_camera and core_camera.getPosition() or vec3()
  return p.x, p.y, p.z, nil
end

-- texte lisible pour un nom de lieu (les installations du jeu ont des clés de traduction)
local function readable(s)
  if type(s) ~= 'string' then return s end
  if not s:match('^[%w_%-]+%.[%w_%-%.]+$') then return s end
  if _tr then
    local ok, t = pcall(_tr, s, s)
    if ok and type(t) == 'string' and t ~= s and t ~= '' then return t end
  end
  local last
  for part in s:gmatch('[^%.]+') do
    if part ~= 'name' and part ~= 'title' and part ~= 'description' then last = part end
  end
  last = (last or s):gsub('[_%-]+', ' '):gsub('(%l)(%u)', '%1 %2')
  return (last:gsub('^%l', string.upper))
end

---------------------------------------------------------------------------
-- points de livraison perso
---------------------------------------------------------------------------
local function pointsFile(lvl) return POINTS_DIR .. lvl .. '.json' end

local function getPoints(lvl)
  lvl = lvl or levelName()
  if not lvl then return {} end
  if not pointsCache[lvl] then
    local data = jsonReadFile(pointsFile(lvl))
    pointsCache[lvl] = (type(data) == 'table' and type(data.points) == 'table') and data.points or {}
  end
  return pointsCache[lvl]
end

local function savePoints(lvl)
  lvl = lvl or levelName()
  if not lvl then return end
  ensureDir(POINTS_DIR)
  writeJson(pointsFile(lvl), {version = 1, level = lvl, points = getPoints(lvl)})
  if levelData and levelData.name == lvl then
    levelData.customCands = locLib.attachCustom(levelData.g, getPoints(lvl))
  end
end

---------------------------------------------------------------------------
-- données de la map (graphe, lieux)
---------------------------------------------------------------------------
local sendState
local function classifySitesFile(p)
  p = p:lower()
  if p:find('residential') or p:find('house') or p:find('home') then return 'home', 'Résidence' end
  if p:find('fuel') or p:find('gasstation') or p:find('gas_station') then return 'poi', 'Station-service' end
  if p:find('mechanic') or p:find('garage') then return 'poi', 'Garage' end
  if p:find('restaurant') then return 'poi', 'Restaurant' end
  if p:find('warehouse') or p:find('industrial') or p:find('factory') then return 'poi', 'Entrepôt' end
  if p:find('shop') or p:find('mixed') or p:find('office') or p:find('store') then return 'poi', 'Commerce' end
  if p:find('facilit') or p:find('dealer') then return 'poi', "Lieu d'intérêt" end
  return 'parking', 'Parking'
end

local SKIP_SITES = {'drift', 'race', 'bounds', 'crawl', 'drag', 'rally', 'mission', 'scenario', 'timetrial', 'chase', 'derby', 'busroute'}

-- Journal des étapes de l'analyse, écrit sur le disque à chaque étape : si le jeu se fige quand même
-- (dans une fonction du jeu), le fichier indique où.
local traceBuf, traceT0 = {}, 0
local function traceWrite()
  pcall(function()
    ensureDir(DATA_DIR)
    if writeFile then writeFile(ANALYSIS_FILE, table.concat(traceBuf, '\n') .. '\n') end
  end)
end
local function traceStart(lvl)
  traceT0 = os.clock()
  traceBuf = {string.format('Livraison Libre %s - analyse de la map %s - %s', VERSION, tostring(lvl), os.date('%d/%m/%Y %H:%M:%S'))}
  traceWrite()
end
local function trace(msg)
  traceBuf[#traceBuf + 1] = string.format('%8.0f ms  %s', (os.clock() - traceT0) * 1000, msg)
  traceWrite()
  log('I', logTag, 'analyse : ' .. msg)
end

-- fichiers *.sites.json de la map : liste déjà établie par le jeu (pas de nouvelle recherche sur le disque)
local function levelSitesFiles(lvl, sm)
  if sm.getSitesFilesByLevel then
    local ok, byLevel = pcall(sm.getSitesFilesByLevel)
    if ok and type(byLevel) == 'table' then return byLevel[lvl:lower()] or byLevel[lvl] or {} end
  end
  local ok, files = pcall(function() return FS:findFiles('/levels/' .. lvl .. '/', '*.sites.json', 3, true, false) end)
  return (ok and type(files) == 'table') and files or {}
end

local function loadSiteSpots(lvl, tick, step)
  tick = tick or function() end
  step = step or function() end
  local spots = {}
  local sm = ensureExt('gameplay_sites_sitesManager')
  if not sm or not FS then return spots end

  -- noms des installations (garages, stations, vendeurs...) associés aux places de parking
  step('installations (garages, stations, vendeurs)')
  local spotInfo = {}
  local fac = ensureExt('freeroam_facilities')
  if fac and fac.getFacilities then
    local ok, all = pcall(fac.getFacilities, lvl)
    if ok and type(all) == 'table' then
      for _, list in pairs(all) do
        if type(list) == 'table' then
          for _, f in ipairs(list) do
            if type(f) == 'table' then
              local function add(n)
                if type(n) == 'string' and not spotInfo[n] then spotInfo[n] = {label = f.name, ftype = f.type} end
              end
              for _, n in ipairs(f.parkingSpotNames or {}) do add(n) end
              for _, n in ipairs(f.dropOffSpotNames or {}) do add(n) end
              for _, ap in ipairs(f.manualAccessPoints or {}) do if type(ap) == 'table' then add(ap.psName) end end
            end
          end
        end
      end
    end
  end
  tick()

  step('liste des fichiers de parkings')
  local files = levelSitesFiles(lvl, sm)
  for _, file in ipairs(files) do
    local lf = tostring(file):lower()
    local skip = false
    for _, w in ipairs(SKIP_SITES) do if lf:find(w, 1, true) then skip = true break end end
    if not skip then
      step('parkings : ' .. tostring(file))
      local ok, sites = pcall(sm.loadSites, file)
      tick()
      if ok and type(sites) == 'table' and sites.parkingSpots and type(sites.parkingSpots.sorted) == 'table' then
        local fileKind, fileLabel = classifySitesFile(file)
        local n = 0
        for _, ps in ipairs(sites.parkingSpots.sorted) do
          n = n + 1
          if n % 128 == 0 then tick() end
          if ps.pos and ps.rot and ps.scl and not ps.missing then
            local fwd = ps.rot * vec3(0, 1, 0)
            local info = ps.name and spotInfo[ps.name]
            local kind, label = fileKind, fileLabel
            if info then
              kind = (info.ftype == 'privateSeller') and 'home' or 'poi'
              label = info.label or label
            end
            spots[#spots + 1] = {
              name = ps.name, label = label, kind = kind,
              x = ps.pos.x, y = ps.pos.y, z = ps.pos.z,
              fx = fwd.x, fy = fwd.y, fz = fwd.z,
              w = ps.scl.x, l = ps.scl.y,
              ps = ps,
            }
          end
        end
      end
    end
  end
  return spots
end

-- Analyse complète de la map. tick : pause/abandon (nil = d'une traite), step : étape en cours.
local function buildLevelBody(lvl, tick, step)
  step = step or function() end
  step('réseau routier (navgraph)')
  local mapData = map and map.getMap and map.getMap()
  if not mapData or type(mapData.nodes) ~= 'table' or not next(mapData.nodes) then
    return nil, "Cette map n'a pas de réseau routier (navgraph) utilisable."
  end
  local t0 = os.clock()
  step('graphe routier')
  local g = graphLib.build(mapData.nodes, {tick = tick})
  step(string.format('graphe : %d noeuds, %d segments, %d composantes', g.n, g.ne, g.compCount or 0))
  if g.ne == 0 then return nil, "Cette map n'a pas de routes utilisables." end
  local ld = {name = lvl, g = g}
  local rules = (map.getRoadRules and map.getRoadRules()) or {}
  ld.legalSide = rules.rightHandDrive and -1 or 1
  step('bords de route')
  ld.road = locLib.buildRoadSpots(g, {tick = tick})
  step('allées et maisons')
  ld.homes = locLib.buildDeadEnds(g, {tick = tick})
  local okS, spots = pcall(loadSiteSpots, lvl, tick, step)
  if not okS then
    if tostring(spots):find('LL_ANALYSIS_TIMEOUT', 1, true) then error(spots, 0) end
    log('W', logTag, 'Lecture des parkings impossible : ' .. tostring(spots)); spots = {}
  end
  step(string.format('rattachement de %d places de parking', #spots))
  ld.spots = locLib.attachSpots(g, spots, {tick = tick})
  ld.cands = {}
  for _, list in ipairs({ld.road, ld.homes, ld.spots}) do
    for _, c in ipairs(list) do ld.cands[#ld.cands + 1] = c end
  end
  ld.customCands = locLib.attachCustom(g, getPoints(lvl))
  log('I', logTag, string.format('Map %s analysée en %.0f ms : %d noeuds, %d segments, %d bords de route, %d allées, %d places',
    lvl, (os.clock() - t0) * 1000, g.n, g.ne, #ld.road, #ld.homes, #ld.spots))
  return ld
end

local function finishAnalysis(ld, err)
  local a = analysis
  analysis = nil
  if ld then levelData = ld end
  if a then
    for _, cb in ipairs(a.waiters) do
      local ok, e = pcall(cb, ld, err)
      if not ok then log('E', logTag, 'après analyse : ' .. tostring(e)) end
    end
  end
  sendState()
end

-- avance l'analyse en cours d'une tranche (appelé à chaque image)
local function stepAnalysis()
  local a = analysis
  if not a then return end
  if a.lvl ~= levelName() then analysis = nil return end
  a.frameStart = os.clock()
  local ok, res, err = coroutine.resume(a.co)
  if not ok then
    local msg = tostring(res)
    analysisErrors = analysisErrors + 1
    if analysisErrors <= 3 then log('E', logTag, 'Analyse de la map abandonnée : ' .. msg) end
    trace('ÉCHEC : ' .. msg)
    local timeout = msg:find('LL_ANALYSIS_TIMEOUT', 1, true)
    finishAnalysis(nil, timeout
      and ("Analyse de la map trop longue (étape : " .. tostring(a.step) .. "). Détails : settings/livraisonLibre/analyse.txt")
      or ("Analyse de la map impossible (" .. msg:sub(1, 120) .. ")."))
  elseif coroutine.status(a.co) == 'dead' then
    trace(res and 'TERMINÉ' or ('ÉCHEC : ' .. tostring(err)))
    finishAnalysis(res, err)
  end
end

-- Lance (ou rejoint) l'analyse de la map actuelle ; cb(levelData | nil, erreur) à la fin.
local function analyzeLevel(cb)
  local lvl = levelName()
  if not lvl then if cb then cb(nil, 'Aucune map chargée.') end return end
  if levelData and levelData.name == lvl then if cb then cb(levelData) end return end
  if analysis and analysis.lvl == lvl then
    if cb then table.insert(analysis.waiters, cb) end
    return
  end
  local a = {lvl = lvl, t0 = os.clock(), frameStart = os.clock(), waiters = {cb}, step = 'démarrage'}
  analysis = a
  local function tick()
    local now = os.clock()
    if now - a.t0 > ANALYSIS_TIMEOUT then error('LL_ANALYSIS_TIMEOUT : plus de ' .. ANALYSIS_TIMEOUT .. ' s pendant « ' .. tostring(a.step) .. ' »', 0) end
    if now - a.frameStart > ANALYSIS_BUDGET then coroutine.yield() end
  end
  traceStart(lvl)
  a.co = coroutine.create(function()
    return buildLevelBody(lvl, tick, function(msg) a.step = msg; trace(msg) end)
  end)
  sendState()
  stepAnalysis()
end

-- Données de la map, d'une traite (secours si une mission en a besoin et qu'elles manquent)
local function buildLevel()
  local lvl = levelName()
  if not lvl then return nil, 'Aucune map chargée.' end
  if levelData and levelData.name == lvl then return levelData end
  analysis = nil
  traceStart(lvl)
  local ld, err = buildLevelBody(lvl, nil, trace)
  trace(ld and 'TERMINÉ' or ('ÉCHEC : ' .. tostring(err)))
  if ld then levelData = ld end
  return ld, err
end

local function locFilter()
  return {kinds = settings.locKinds, paved = settings.surface == 'paved', pavedThreshold = settings.pavedThreshold, avoidHighways = settings.avoidHighways}
end

local function mapCounts()
  if not levelData then return nil end
  local f = locFilter()
  f.kinds = nil
  local counts = {road = 0, parking = 0, poi = 0, home = 0}
  for _, c in ipairs(levelData.cands) do
    if locLib.eligible(c, f) then counts[c.kind] = (counts[c.kind] or 0) + 1 end
  end
  return counts
end

---------------------------------------------------------------------------
-- véhicules
---------------------------------------------------------------------------
local function ensurePool()
  if vehPool then return vehPool end
  if not core_vehicles then return nil end
  local t0 = os.clock()
  local ok, res = pcall(function()
    local list = core_vehicles.getConfigList(true)
    return vehLib.buildPool(list and list.configs or {}, function(key)
      local m = core_vehicles.getModel(key)
      return m and m.model
    end)
  end)
  if ok and res then
    vehPool = res
    log('I', logTag, string.format('%d modèles / %d configs pilotables chargés en %.0f ms', #res.models, res.count, (os.clock() - t0) * 1000))
  else
    log('E', logTag, 'Chargement des véhicules impossible : ' .. tostring(res))
  end
  return vehPool
end

-- boîte de vitesses des configs qui ne l'indiquent pas : déduite des pièces, seulement si le filtre sert
local function ensureTransmissions()
  if vehPool and not vehPool.transInferred and settings.veh.transmission ~= 'both' then
    local t0 = os.clock()
    local n = vehLib.inferTransmissions(vehPool, function(p) return jsonReadFile(p) end)
    log('I', logTag, string.format('boîte de vitesses déduite pour %d configs en %.0f ms', n, (os.clock() - t0) * 1000))
  end
end

local function vehicleCounts()
  if not vehPool then return {loaded = false} end
  ensureTransmissions()
  local eligible, cfgCount = vehLib.eligibleModels(vehPool, settings.veh)
  return {loaded = true, models = #vehPool.models, configs = vehPool.count, eligibleModels = #eligible, eligibleConfigs = cfgCount}
end

local function pickVehicleInfo()
  local pool = ensurePool()
  if not pool then return nil, 'Impossible de lire la liste des véhicules.' end
  ensureTransmissions()
  local eligible = vehLib.eligibleModels(pool, settings.veh)
  if #eligible == 0 then return nil, 'Aucun véhicule ne correspond à tes filtres (onglet Véhicules).' end
  if next(badModels) then
    -- évite les modèles qui ont déjà échoué au spawn
    local ok = {}
    for _, e in ipairs(eligible) do if not badModels[e.model.key] then ok[#ok + 1] = e end end
    if #ok > 0 then eligible = ok end
  end
  local recent = (S and S.recent) or {}
  local keep = min(6, floor(#eligible / 2))
  local trimmed = {}
  for i = max(1, #recent - keep + 1), #recent do trimmed[#trimmed + 1] = recent[i] end
  return vehLib.pick(eligible, math.random, trimmed)
end

local function randomPaints(info)
  if not settings.randomPaint or info.variant ~= 'usine' then return nil end
  local vp = ensureExt('core_vehiclePaints')
  if not vp or not vp.getRandomPaints then return nil end
  local ok, res = pcall(function()
    local rp = vp.getRandomPaints(info.model, info.config)
    if not rp or not rp.paintName1 then return nil end
    local model = core_vehicles.getModel(info.model)
    local paints = model and model.model and model.model.paints or {}
    local p1 = paints[rp.paintName1]
    if not p1 then return nil end
    return {p1, paints[rp.paintName2] or p1, paints[rp.paintName3] or p1}
  end)
  if ok then return res end
  return nil
end

local function vehicleSize(veh, info)
  local ok, ext = pcall(function() return veh.initialNodePosBB:getExtents() end)
  if ok and ext and ext.x and ext.x > 0.5 and ext.y > 1 then
    local w, l = ext.x, ext.y
    if w > l then w, l = l, w end
    return w, l
  end
  return info and info.w or 2, info and info.l or 4.8
end

local function configKeyOf(veh)
  local pc = veh.partConfig
  if type(pc) == 'string' then return pc:match('vehicles/[^/]+/([^/]+)%.pc$') end
  return nil
end

-- Fiche d'un véhicule déjà présent dans le monde (changement de véhicule par le joueur)
local function infoFromVehicle(veh)
  local model = veh.JBeam
  if type(model) ~= 'string' or model == '' then return nil end
  local cfgKey = configKeyOf(veh)
  local pool = ensurePool()
  local pm = pool and pool.byModel[model]
  if pm and cfgKey then
    for _, info in ipairs(pm.configs) do
      if info.config == cfgKey then return info end
    end
  end
  local okM, md = pcall(core_vehicles.getModel, model)
  local mm = okM and type(md) == 'table' and md.model or nil
  if cfgKey and okM and type(md) == 'table' and md.configs and md.configs[cfgKey] then
    local ok, info = pcall(vehLib.classify, md.configs[cfgKey], mm)
    if ok and info then return info end
  end
  local name = (mm and mm.Name) or model
  return {
    model = model, config = cfgKey, name = cfgKey and (name .. ' ' .. cfgKey) or (name .. ' (config perso)'),
    modelName = name, brand = (mm and mm.Brand) or '', preview = (pm and pm.preview) or (mm and mm.preview),
    source = (mm and mm.Source) or '', srcKind = 'perso', mainCat = (pm and pm.configs[1] and pm.configs[1].mainCat) or 'autre',
    cats = {autre = true}, epochs = {inconnue = true}, variant = 'custom', w = 2, l = 4.8,
  }
end

---------------------------------------------------------------------------
-- zone, marqueurs, GPS
---------------------------------------------------------------------------
local function isZoneFree(zone)
  local r = max(zone.w, zone.l) * 0.5 + 0.8
  local ignore = S and S.vehId
  -- le véhicule actuel du joueur sera remplacé au lancement : il ne bloque pas un emplacement
  local ignoreOwn = (S and S.first and not settings.keepOwnVehicle) and be:getPlayerVehicleID(0) or nil
  for i = 0, be:getObjectCount() - 1 do
    local obj = be:getObject(i)
    if obj then
      local id = obj:getID()
      if id ~= ignore and id ~= ignoreOwn then
        local x, y, z = be:getObjectOOBBCenterXYZ(id)
        local dx, dy, dz = x - zone.x, y - zone.y, z - zone.z
        if dx * dx + dy * dy < r * r and abs(dz) < 4 then return false end
      end
    end
  end
  return true
end

local function groundZ(x, y, z)
  local ok, h = pcall(function() return be:getSurfaceHeightBelow(vec3(x, y, z + 2.5)) end)
  if ok and h and h > z - 4 and h < z + 3 then return h end
  return z
end

-- réserve la place de destination (et les places du parking du jeu qui chevauchent la zone)
-- pour que les voitures garées du jeu ne s'y mettent pas
local function releaseSpot()
  for _, r in ipairs(reservedList) do
    if r.ps.vehicle == r.val then r.ps.vehicle = nil end
  end
  reservedList = {}
end

local function reserveSpot(dest, zone)
  releaseSpot()
  dest = dest or (S and S.dest)
  zone = zone or (S and S.zone)
  local val = (S and S.vehId) or -1
  local ps = dest and dest.ps
  if type(ps) == 'table' and ps.vehicle == nil then
    ps.vehicle = val
    reservedList[#reservedList + 1] = {ps = ps, val = val}
  end
  if zone and zone.w and zone.l then
    local r = sqrt((zone.w * 0.5) ^ 2 + (zone.l * 0.5) ^ 2) + 3
    for _, p in ipairs(trafficCtl.reserveParkingNear(zone.x, zone.y, zone.z, r, val)) do
      reservedList[#reservedList + 1] = {ps = p, val = val}
    end
  end
end

local function removeMarker()
  if marker then
    pcall(function() marker:clearMarkers() end)
    marker = nil
  end
end

local function createMarker()
  removeMarker()
  if not S or not S.zone or not settings.showArrow then return end
  local ok, ctor = pcall(require, 'scenario/raceMarkers/attention')
  if not ok or type(ctor) ~= 'function' then return end
  markerSeq = markerSeq + 1
  local ok2, mk = pcall(ctor, 774100 + markerSeq)
  if not ok2 or not mk then return end
  local ok3 = pcall(function()
    mk:createMarkers()
    mk:setToCheckpoint({pos = vec3(S.zone.x, S.zone.y, S.zone.z + 2.8), radius = 1.6})
    mk:setMode('default')
    mk:show()
  end)
  if ok3 then marker = mk else pcall(function() mk:clearMarkers() end) end
end

local function setRoute()
  local gm = ensureExt('core_groundMarkers')
  if gm and S and S.zone then
    pcall(gm.setPath, vec3(S.zone.x, S.zone.y, S.zone.z), {clearPathOnReachingTarget = false})
  end
end

local function clearRoute()
  if core_groundMarkers then pcall(core_groundMarkers.setPath, nil) end
end

local function clearVisuals()
  removeMarker()
  clearRoute()
  releaseSpot()
end

---------------------------------------------------------------------------
-- état envoyé à l'interface
---------------------------------------------------------------------------
local function candInfo(c)
  if not c then return nil end
  return {kind = c.kind, kindLabel = KIND_LABEL[c.kind] or '', label = c.label or KIND_LABEL[c.kind] or 'Destination'}
end

local function sessionInfo()
  if not S then return nil end
  local info = S.info
  return {
    phase = S.phase,
    count = S.count,
    relaxed = S.relaxed,
    loadingTraffic = S.waitTraffic and not trafficCtl.isReady() or false,
    vehicle = info and {
      name = info.name, brand = info.brand, years = info.yearsText, preview = info.preview,
      model = info.model, source = info.source, cat = info.mainCat, variant = info.variant,
      trans = info.trans and TRANS_LABEL[info.trans] or nil,
    } or nil,
    from = candInfo(S.pickup),
    to = candInfo(S.dest),
    routeDist = S.routeDist,
    timeLimit = S.timeLimit,
    summary = S.summary,
    message = S.message,
  }
end

local function pointsForUI()
  local lvl = levelName()
  if not lvl then return {} end
  local px, py, pz = playerPos()
  local out = {}
  for _, p in ipairs(getPoints(lvl)) do
    local dx, dy, dz = p.pos.x - px, p.pos.y - py, p.pos.z - pz
    out[#out + 1] = {id = p.id, name = p.name, dist = sqrt(dx * dx + dy * dy + dz * dz)}
  end
  return out
end

-- listes pour l'UI (sans les bornes ±infini des époques, non encodables en JSON)
local function uiList(list)
  local out = {}
  for i, e in ipairs(list) do out[i] = {id = e.id, label = e.label} end
  return out
end
local UI_META = {
  categories = uiList(vehLib.CATEGORIES), epochs = uiList(vehLib.EPOCHS),
  variants = uiList(vehLib.VARIANTS), sources = uiList(vehLib.SOURCES), transmissions = uiList(vehLib.TRANSMISSIONS),
}

local function journalInfo()
  local path = 'settings/livraisonLibre/livraisons.csv'
  if FS and FS.getUserPath then
    local ok, up = pcall(function() return FS:getUserPath() end)
    if ok and type(up) == 'string' then path = (up .. path):gsub('/', '\\') end
  end
  return {count = #journalRecords, path = path}
end

local function buildState()
  return {
    version = VERSION,
    level = levelName(),
    levelReady = levelData ~= nil and levelData.name == levelName(),
    analysing = (analysis ~= nil) or nil,
    analysisStep = analysis and analysis.step or nil,
    startPending = startPending or nil,
    settings = settings,
    stats = stats,
    session = sessionInfo(),
    vehicles = vehicleCounts(),
    map = levelData and levelData.name == levelName() and {counts = mapCounts(), legalSide = levelData.legalSide} or nil,
    traffic = trafficCtl.status(),
    journal = journalInfo(),
    points = pointsForUI(),
    meta = UI_META,
  }
end

sendState = function()
  guihooks.trigger('LivraisonLibreState', buildState())
end

---------------------------------------------------------------------------
-- mesures de la mission en cours (journal)
---------------------------------------------------------------------------
local function newMetrics()
  return {odo = 0, vmax = 0, resets = 0, pursuits = 0, arrests = 0, dmgBase = 0, dmgLast = 0, dmgTimer = 0,
          used = {}, switches = 0, segDist = 0,
          moveAt = nil, odoAtMove = nil, nearAt = nil, odoAtNear = nil,
          speedWin = {}, ignoreUntil = 1.0,
          stars = 0, maxStars = 0, policeSeen = false, pursuitTime = 0}
end

-- ignore les mesures de vitesse un court instant (reset, récupération, changement de véhicule)
local function pauseMeasures(seconds)
  local m = S and S.m
  if not m then return end
  m.ignoreUntil = (S.elapsed or 0) + (seconds or 1.5)
  m.speedWin = {}
end

-- temps et distance du trajet "chronométré" (1re accélération -> 50 m de la zone)
local function perfTime()
  local m = S and S.m
  if not m or not m.moveAt then return 0 end
  return max(0, (m.nearAt or S.elapsed or 0) - m.moveAt)
end

local function perfDist()
  local m = S and S.m
  if not m or not m.moveAt then return 0 end
  return max(0, (m.odoAtNear or m.odo) - (m.odoAtMove or 0))
end

local function perfAvgKmh()
  local t = perfTime()
  if t < 1 then return 0 end
  return perfDist() / t * 3.6
end

-- Ferme le "segment" du véhicule actuel quand on en change :
-- noté (et compté comme changement) seulement si on a roulé au moins 500 m avec.
local function closeSegment()
  local m = S and S.m
  if not m or not S.info then return end
  if m.segDist >= SWITCH_MIN_DIST then
    m.used[#m.used + 1] = {name = S.info.name, dist = m.segDist}
    m.switches = m.switches + 1
  end
  m.segDist = 0
  m.dmgBase = m.dmgBase + m.dmgLast
  m.dmgLast = 0
end

local function recordMission(result, reason)
  if not S or not S.m or S.recorded then return nil end
  S.recorded = true
  local m, info = S.m, S.info or {}
  local used = {}
  for _, u in ipairs(m.used) do used[#used + 1] = u end
  used[#used + 1] = {name = info.name or '?', dist = m.segDist}
  local ts = trafficCtl.status()
  local police = 'Aucune'
  if settings.traffic.mode == 'on' and settings.traffic.police ~= 'off' then
    police = POLICE_LABEL[settings.traffic.police]
  elseif ts.police > 0 then
    police = 'Patrouilles'
  end
  journalSeq = journalSeq + 1
  local fromName = S.pickup and readable(S.pickup.label or KIND_LABEL[S.pickup.kind]) or 'Ma position'
  local toName = S.dest and readable(S.dest.label or KIND_LABEL[S.dest.kind]) or '?'
  local rec = journal.makeRecord({
    id = journalSeq, date = os.date('%d/%m/%Y'), heure = os.date('%H:%M:%S'), map = levelName(),
    result = result, reason = reason,
    vehicle = info.name, brand = info.brand, model = info.model, config = info.config,
    category = CAT_LABEL[info.mainCat or 'autre'], years = info.yearsText, source = info.source,
    transmission = info.trans and TRANS_LABEL[info.trans] or '',
    used = used, switches = m.switches,
    fromKind = S.pickup and KIND_LABEL[S.pickup.kind] or 'Ma position', fromName = fromName,
    toKind = S.dest and KIND_LABEL[S.dest.kind] or '', toName = toName,
    plannedDist = S.routeDist or 0, drivenDist = m.odo, tripDist = perfDist(),
    tripTime = perfTime(), totalTime = S.elapsed or 0, vmax = m.vmax,
    startDelay = m.moveAt,
    parkTime = (result == 'Livrée' and m.nearAt) and ((S.elapsed or 0) - m.nearAt) or nil,
    resets = m.resets, damage = m.dmgBase + m.dmgLast,
    traffic = ts.active, trafficCount = ts.amount, parkedCount = ts.parked, police = police,
    pursuits = m.pursuits, arrests = m.arrests, maxStars = m.maxStars, pursuitTime = m.pursuitTime,
    timeLimit = S.timeLimit,
    locMode = settings.locMode == 'custom' and 'Mes points' or 'Aléatoire',
    surface = settings.surface == 'paved' and 'Bitume' or 'Toutes routes',
    validation = settings.validation == 'auto' and 'Auto (3 s)' or 'Frein à main',
    zoneScale = settings.zoneScale,
  })
  journalRecords[#journalRecords + 1] = rec
  saveJournal()

  table.insert(stats.history, 1, {
    ok = result == 'Livrée', result = result, reason = reason,
    vehicle = info.name or '?', from = fromName, to = toName,
    dist = S.routeDist or 0, driven = m.odo, time = perfTime(), total = S.elapsed or 0, avg = rec.avgKmh or 0,
    resets = m.resets, switches = m.switches, traffic = ts.active, level = levelName(), date = os.date('%d/%m %H:%M'),
    maxStars = m.maxStars or 0, pursuitTime = m.pursuitTime or 0,
  })
  while #stats.history > HISTORY_MAX do table.remove(stats.history) end
  return rec
end

---------------------------------------------------------------------------
-- déroulement des missions
---------------------------------------------------------------------------
local prepareNext

local function newSession()
  return {
    phase = 'idle', count = 0, recent = {}, first = true,
    elapsed = 0, parkBrake = 0, speed = 0, inZone = false, validate = 0, validateTimer = 0,
    pbTimer = 0, zoneDist = 1e9, phaseTimer = 0, recorded = true,
  }
end

local function endFade()
  if S and S.faded then
    S.faded = false
    local fs = ensureExt('ui_fadeScreen')
    if fs then pcall(fs.fadeFromBlack, 0.6) end
  end
end

-- Le résumé n'est affiché que lorsque l'écran est visible : tout de suite si on reste sur place,
-- sinon une fois la livraison suivante chargée (après le fondu et le téléport).
local function queueSummary(payload)
  local willLoadNext = settings.autoNext or (settings.instantNext and settings.validation ~= 'auto')
  if willLoadNext then
    S.pendingSummary = payload
    S.summaryDelay = nil
  else
    guihooks.trigger('LivraisonLibreSummary', payload)
  end
end

local function flushSummary()
  if S and S.pendingSummary then
    guihooks.trigger('LivraisonLibreSummary', S.pendingSummary)
    S.pendingSummary, S.summaryDelay = nil, nil
  end
end

-- Retour de force coupé pendant les chargements : à bas FPS (spawn, trafic, fondu), le calcul du
-- retour de force devient instable et le volant part dans tous les sens.
local FFB_HOLD_ON = [[
if hydros and hydros._llFfbHold == nil then
  hydros._llFfbHold = hydros.enableFFB and true or false
  hydros.enableFFB = false
  local id = hydros.getFFBID and hydros.getFFBID() or -1
  if id and id >= 0 then
    local send = (hydros.getForceFeedbackFunction and hydros.getForceFeedbackFunction()) or obj.sendForceFeedback
    pcall(send, obj, id, 0, 0, 0, 0)
  end
end]]
local FFB_HOLD_OFF = [[if hydros and hydros._llFfbHold ~= nil then hydros.enableFFB = hydros._llFfbHold; hydros._llFfbHold = nil end]]

local function holdFFB(id)
  if not settings.ffbGuard or not id or id < 0 then return end
  local obj = getObjectByID(id)
  if obj then
    pcall(obj.queueLuaCommand, obj, FFB_HOLD_ON)
    ffbHeld[id] = true
  end
end

local function releaseFFB(id)
  if not id or not ffbHeld[id] then return end
  ffbHeld[id] = nil
  local obj = getObjectByID(id)
  if obj then pcall(obj.queueLuaCommand, obj, FFB_HOLD_OFF) end
end

local function releaseAllFFB()
  local ids = {}
  for id in pairs(ffbHeld) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do releaseFFB(id) end
  ffbHeld = {}
end

local function stopSession(silent)
  if S then
    flushSummary() -- pas de chargement à venir : on peut afficher le résumé en attente
    if S.phase == 'driving' or S.phase == 'lost' then
      if recordMission('Arrêtée') then saveStats() end
    end
    trafficCtl.resetPursuit(S.vehId)
    trafficCtl.clearSirenPatches()
    trafficCtl.resetTuning()
    releaseAllFFB()
    if settings.traffic.mode == 'on' and settings.traffic.removeOnStop then trafficCtl.removeOwned() end
    endFade()
  end
  clearVisuals()
  S = nil
  if not silent then sendState() end
end

local function planMission(w, l, fromHere)
  local ld, err = buildLevel()
  if not ld then return nil, err end
  local ctx = {
    g = ld.g,
    minD = settings.minDist, maxD = settings.maxDist,
    vehW = w, vehL = l, scale = settings.zoneScale, legalSide = ld.legalSide,
    rng = math.random,
    filter = locFilter(),
    isFree = isZoneFree,
    exclude = (S and S.dest) and {[S.dest.id] = true} or nil,
  }
  if settings.locMode == 'custom' then
    ctx.customMode = true
    ld.customCands = locLib.attachCustom(ld.g, getPoints(ld.name))
    ctx.cands = ld.customCands
  else
    ctx.cands = ld.cands
  end
  if fromHere then
    local px, py, pz = playerPos()
    local ei, t, d = graphLib.nearestEdge(ld.g, px, py, pz, 400, nil, 20)
    ctx.from = {x = px, y = py, z = pz, e = ei, t = t, off = d or 0}
  end
  local res, reason = locLib.pickMission(ctx)
  if not res and reason == 'no_destination' then
    -- tous les emplacements possibles sont occupés : on ignore l'occupation plutôt que d'échouer
    ctx.isFree = nil
    res, reason = locLib.pickMission(ctx)
  end
  if not res and not ctx.customMode and reason ~= 'need_points' then
    ctx.filter.kinds = nil
    res, reason = locLib.pickMission(ctx)
    if res then res.kindsRelaxed = true end
  end
  if not res then return nil, REASONS[reason] or tostring(reason) end
  return res
end

local function spawnOptions(info, pos, rot)
  local opts = {
    config = info.pc or info.config,
    autoEnterVehicle = true,
    centeredPosition = true,
    canSpawnAnotherVehicleCheck = false,
  }
  if pos then opts.pos = pos end
  if rot then opts.rot = rot end
  local paints = randomPaints(info)
  if paints then opts.paint, opts.paint2, opts.paint3 = paints[1], paints[2], paints[3] end
  return opts
end

local function deleteVehicle(id)
  if not id then return end
  local obj = getObjectByID(id)
  if obj then
    if S then S.expectDelete = S.expectDelete or {}; S.expectDelete[id] = true end
    pcall(function() obj:delete() end)
  end
end

local function placeZone(dirSign)
  local legal = levelData and levelData.legalSide or 1
  local zone = locLib.zoneFor(S.dest, S.vehW, S.vehL, settings.zoneScale, legal, dirSign or 1, true)
  zone.z = groundZ(zone.x, zone.y, zone.z)
  S.zone = zone
end

local function beginDriving()
  local veh = S.vehId and getObjectByID(S.vehId)
  if not veh then error('vehicule introuvable apres le spawn') end
  S.vehW, S.vehL = vehicleSize(veh, S.info)
  local plan = S.plan
  S.dest, S.pickup = plan.dest, plan.pickup
  placeZone(plan.destZone and plan.destZone.dirSign or 1)
  S.routeDist = max(plan.dist or 0, 50)
  S.relaxed = plan.relaxed or plan.kindsRelaxed
  S.validateTimer, S.validate, S.inZone, S.parkBrake = 0, 0, false, 0
  local quiet = false
  if S.keepTimer then
    -- simple changement de véhicule : on garde le chrono et les mesures de la mission
    S.elapsed, S.timeLimit = S.keepTimer.elapsed or 0, S.keepTimer.limit
    S.keepTimer = nil
    quiet = true
  else
    S.elapsed = 0
    S.timeLimit = settings.timeLimit and (S.routeDist / (settings.avgSpeedKmh / 3.6) + settings.timeBonus) or nil
    S.m = newMetrics()
    S.recorded = false
    trafficCtl.resetTuning()
    S.wanted = nil
    if settings.traffic.mode == 'on' and settings.traffic.police == 'wanted' then
      S.wanted = {timer = 2.5, tries = 0}
    end
  end
  S.waitTraffic = false
  if S.freshTraffic then
    S.freshTraffic = false
  elseif S.teleported and not quiet then
    trafficCtl.scatter()
  end
  S.teleported = false
  S.summary = nil
  S.phase = 'driving'
  S.plan = nil
  reserveSpot()
  S.clearTimer = 0
  setRoute()
  createMarker()
  endFade()
  if next(ffbHeld) then S.ffbRelease = FFB_RELEASE_DELAY end
  if S.pendingSummary then S.summaryDelay = SUMMARY_DELAY end
  S.message = nil
  if S.relaxed then S.message = 'Distance demandée introuvable : destination la plus proche choisie.' end
  if not quiet then
    ui_message(string.format('Livraison n°%d : %s → %s', S.count + 1, fmtDist(S.routeDist), readable(candInfo(S.dest).label)), 6, 'livraisonLibre', 'info')
  end
  sendState()
end

-- Spawn du véhicule au point de départ (écran noir si fondu activé)
local function doSpawn()
  local p = S.pending
  S.pending = nil
  S.phase = 'spawning'           -- ignore les hooks de changement de véhicule pendant notre spawn
  local info, plan = p.info, p.plan
  local oldId = S.vehId
  local ownId = S.first and not settings.keepOwnVehicle and be:getPlayerVehicleID(0) or nil
  if ownId and ownId < 0 then ownId = nil end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then ownId = nil end
  local veh
  for attempt = 1, 3 do
    local ok, res = pcall(function()
      if p.fromHere then
        local cur = getPlayerVehicle(0)
        if cur and (cur:getID() == oldId or (S.first and not settings.keepOwnVehicle)) then
          ownId = nil
          return core_vehicles.replaceVehicle(info.model, spawnOptions(info))
        end
        return core_vehicles.spawnNewVehicle(info.model, spawnOptions(info))
      end
      local z = plan.pickupZone
      local pos = vec3(z.x, z.y, z.z + 0.3)
      local rot = quatFromDir(vec3(z.fx, z.fy, z.fz), vec3(z.ux, z.uy, z.uz))
      return core_vehicles.spawnNewVehicle(info.model, spawnOptions(info, pos, rot))
    end)
    if ok and res then veh = res break end
    -- véhicule (souvent un mod) impossible à spawner : on en prend un autre
    log('W', logTag, 'Spawn impossible pour ' .. tostring(info.model) .. ' : ' .. tostring(res))
    badModels[info.model] = true
    local other = pickVehicleInfo()
    if not other then break end
    info = other
  end
  if not veh then error('le spawn du vehicule a echoue (' .. tostring(info.model) .. ')') end
  local newId = veh:getID()
  holdFFB(newId)
  S.vehId = newId
  S.info = info
  S.plan = plan
  S.first = false
  S.teleported = not p.fromHere
  if oldId and oldId ~= newId then
    trafficCtl.resetPursuit(oldId)
    deleteVehicle(oldId)
  end
  if ownId and ownId ~= newId and ownId ~= oldId then deleteVehicle(ownId) end
  table.insert(S.recent, info.model)
  while #S.recent > 12 do table.remove(S.recent, 1) end

  -- trafic : appliqué une fois au lancement, autour de la nouvelle position
  if S.trafficPending then
    S.trafficPending = false
    local res, msg = trafficCtl.apply(settings.traffic, levelName())
    if msg then toast(res == 'error' and 'err' or 'warn', msg) end
    S.waitTraffic = (res == 'waiting')
    S.freshTraffic = (res == 'waiting' or res == 'done')
  end
  S.phaseTimer = 0
  sendState()
end

local function safeCall(fn, what)
  local ok, err = pcall(fn)
  if not ok then
    log('E', logTag, what .. ' : ' .. tostring(err))
    toast('err', 'Livraison Libre : erreur (' .. what .. '). Détails dans la console.')
    stopSession()
  end
  return ok
end

-- Prépare la mission suivante. opts.fromHere : pas de téléport (départ = position actuelle).
prepareNext = function(opts)
  opts = opts or {}
  if not S then return end
  local info, err = pickVehicleInfo()
  if not info then toast('err', err); stopSession(); return end
  local fromHere = opts.fromHere or (S.first and settings.firstStartHere)
  local plan, perr = planMission(info.w, info.l, fromHere)
  if not plan then toast('err', perr); stopSession(); return end
  holdFFB(be:getPlayerVehicleID(0))
  holdFFB(S.vehId)
  S.ffbRelease = nil
  clearVisuals()
  S.zone = nil
  reserveSpot(plan.dest, plan.destZone)
  S.pending = {info = info, plan = plan, fromHere = fromHere}
  S.summary = nil
  local fs = settings.fade and not fromHere and ensureExt('ui_fadeScreen')
  if fs and fs.fadeToBlack then
    S.phase = 'fading'
    S.phaseTimer = 0
    S.blackReached = false
    S.faded = true
    pcall(fs.fadeToBlack, 0.4)
  else
    safeCall(doSpawn, 'spawn')
  end
  sendState()
end

-- données de l'écran de résumé (app indépendante, affichée quelques secondes)
local function summaryPayload(ok, reason, records)
  local m, info = S.m or newMetrics(), S.info or {}
  return {
    ok = ok, reason = reason, count = S.count, showFor = settings.summaryDuration,
    maxStars = m.maxStars or 0, policeActive = (m.policeSeen or (m.maxStars or 0) > 0) and true or false,
    pursuitTime = m.pursuitTime or 0,
    vehicle = info.name, brand = info.brand, preview = info.preview,
    from = S.pickup and readable(S.pickup.label or KIND_LABEL[S.pickup.kind]) or 'Ma position',
    to = S.dest and readable(S.dest.label or KIND_LABEL[S.dest.kind]) or '?',
    tripTime = perfTime(), totalTime = S.elapsed or 0,
    parkTime = (ok and m.nearAt) and ((S.elapsed or 0) - m.nearAt) or nil,
    plannedDist = S.routeDist or 0, tripDist = perfDist(), driven = m.odo,
    avgKmh = perfAvgKmh(), vmaxKmh = m.vmax * 3.6,
    resets = m.resets, damage = floor(m.dmgBase + m.dmgLast + 0.5), switches = m.switches,
    pursuits = m.pursuits, arrests = m.arrests,
    records = records or {}, streak = stats.streak or 0,
  }
end

local function deliver()
  local time = perfTime()
  if time < 1 then time = S.elapsed or 0 end
  local dist = S.routeDist or 0
  local avg = perfAvgKmh()
  local records = {}
  if dist >= 500 and avg > (stats.bestAvg or 0) then stats.bestAvg = avg; records.avg = true end
  if dist >= 500 and (not stats.fastest or time < stats.fastest.time) then
    if stats.fastest then records.fastest = true end
    stats.fastest = {time = time, dist = dist, vehicle = S.info and S.info.name or '?'}
  end
  if dist > (stats.longest or 0) then
    if (stats.longest or 0) > 0 then records.longest = true end
    stats.longest = dist
  end
  stats.delivered = stats.delivered + 1
  stats.distance = stats.distance + dist
  stats.time = stats.time + time
  stats.streak = (stats.streak or 0) + 1
  stats.bestStreak = max(stats.bestStreak or 0, stats.streak)
  local rec = recordMission('Livrée')
  saveStats()
  S.count = S.count + 1
  local payload = summaryPayload(true, nil, records)
  queueSummary(payload)
  S.summary = {ok = true, time = time, total = S.elapsed, dist = dist, avg = avg, record = records.avg or records.fastest or false,
               resets = payload.resets, driven = payload.driven, parkTime = payload.parkTime,
               maxStars = payload.maxStars, pursuitTime = payload.pursuitTime, policeActive = payload.policeActive}
  S.phase = 'summary'
  S.phaseTimer = 0
  trafficCtl.resetPursuit(S.vehId)
  clearVisuals()
  ui_message(string.format('Livraison validée ! %s en %s (%.0f km/h de moyenne)%s', fmtDist(dist), fmtTime(time), avg,
    records.avg and ' - Nouveau record !' or ''), 6, 'livraisonLibre', 'info')
  if settings.instantNext and settings.validation ~= 'auto' then
    prepareNext({}) -- validation éclair : livraison suivante directe (le résumé reste affiché à côté)
  else
    sendState()
  end
  return rec
end

local function failMission(reason)
  reason = reason or 'Temps écoulé'
  recordMission('Ratée', reason)
  stats.failed = stats.failed + 1
  stats.streak = 0
  saveStats()
  local payload = summaryPayload(false, reason)
  queueSummary(payload)
  S.summary = {ok = false, time = perfTime(), total = S.elapsed, reason = reason,
               maxStars = payload.maxStars, pursuitTime = payload.pursuitTime, policeActive = payload.policeActive}
  S.phase = 'failed'
  S.phaseTimer = 0
  clearVisuals()
  ui_message(reason .. ' ! Livraison ratée.', 6, 'livraisonLibre', 'warning')
  sendState()
end

---------------------------------------------------------------------------
-- changement de véhicule par le joueur pendant une livraison
---------------------------------------------------------------------------
local function isAdoptable(id)
  if not id or id < 0 then return false end
  local obj = getObjectByID(id)
  if not obj then return false end
  if obj.JBeam == 'unicycle' or obj.isParked == 'true' then return false end
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then return false end
  local gt = gameplay_traffic
  if gt and gt.getTrafficData then
    local ok, data = pcall(gt.getTrafficData)
    if ok and type(data) == 'table' and data[id] and data[id].isAi then return false end
  end
  return true
end

-- Adapte la zone au gabarit du véhicule ; si l'emplacement est trop petit (camion sur une place
-- de parking, route trop étroite...), la livraison passe à l'emplacement compatible le plus proche.
local function adaptZoneToVehicle()
  local moved = false
  local ld = levelData
  if S.dest and ld and S.dest.kind ~= 'custom' and not locLib.fits(S.dest, S.vehW, S.vehL, settings.zoneScale) then
    local legal = ld.legalSide or 1
    local c, z = locLib.nearestFitting(ld.cands, S.dest.x, S.dest.y, S.vehW, S.vehL, settings.zoneScale, locFilter(), 800, isZoneFree, legal)
    if not c then
      c, z = locLib.nearestFitting(ld.cands, S.dest.x, S.dest.y, S.vehW, S.vehL, settings.zoneScale, nil, 2000, isZoneFree, legal)
    end
    if c then
      releaseSpot()
      S.dest = c
      z.z = groundZ(z.x, z.y, z.z)
      S.zone = z
      moved = true
    end
  end
  if not moved then placeZone(S.zone and S.zone.dirSign or 1) end
  reserveSpot()
  setRoute()
  createMarker()
  return moved
end

local function adoptVehicle(id)
  local veh = getObjectByID(id)
  if not veh then return end
  local info = infoFromVehicle(veh)
  if not info then return end
  local sameObject = (id == S.vehId)
  if sameObject and S.info and S.info.model == info.model then
    if S.info.config == info.config then return end
    if not configKeyOf(veh) then
      -- simple modification des pièces : même véhicule, on adapte juste la zone
      S.vehW, S.vehL = vehicleSize(veh, S.info)
      adaptZoneToVehicle()
      sendState()
      return
    end
  end
  closeSegment()
  if not sameObject and S.vehId then trafficCtl.resetPursuit(S.vehId) end
  S.vehId = id
  S.info = info
  S.vehW, S.vehL = vehicleSize(veh, info)
  S.parkBrake, S.validateTimer, S.validate = 0, 0, 0
  pauseMeasures(2)
  if S.phase == 'lost' then
    S.phase = 'driving'
    S.message = nil
  end
  local moved = adaptZoneToVehicle()
  toast('info', 'Véhicule de livraison : ' .. tostring(info.name) .. (moved and ' (zone déplacée pour ce gabarit)' or ''))
  sendState()
end

local function vehicleChanged(id)
  if not S or (S.phase ~= 'driving' and S.phase ~= 'lost') or not S.dest then return end
  if not isAdoptable(id) then return end
  local ok, err = pcall(adoptVehicle, id)
  if not ok then log('E', logTag, 'changement de véhicule : ' .. tostring(err)) end
end

---------------------------------------------------------------------------
-- vérification de la zone et du frein à main
---------------------------------------------------------------------------
local function vehicleInZone(vid, zone)
  local cx, cy, cz = be:getObjectOOBBCenterXYZ(vid)
  local dx, dy, dz = cx - zone.x, cy - zone.y, cz - zone.z
  if abs(dx * zone.ux + dy * zone.uy + dz * zone.uz) > 4 then return false end
  local ax, ay, az = be:getObjectOOBBHalfAxisXYZ(vid, 0)
  local bx, by, bz = be:getObjectOOBBHalfAxisXYZ(vid, 1)
  local qx, qy, qz = be:getObjectOOBBHalfAxisXYZ(vid, 2)
  local hl, hw = zone.l * 0.5, zone.w * 0.5
  for i = 0, 7 do
    local s0 = (i % 2 == 0) and 1 or -1
    local s1 = (floor(i / 2) % 2 == 0) and 1 or -1
    local s2 = (floor(i / 4) % 2 == 0) and 1 or -1
    local px = dx + ax * s0 + bx * s1 + qx * s2
    local py = dy + ay * s0 + by * s1 + qy * s2
    local pz = dz + az * s0 + bz * s1 + qz * s2
    if abs(px * zone.fx + py * zone.fy + pz * zone.fz) > hl then return false end
    if abs(px * zone.rx + py * zone.ry + pz * zone.rz) > hw then return false end
  end
  return true
end

local function pollParkBrake(veh, vid)
  veh:queueLuaCommand(string.format(
    'obj:queueGameEngineLua("if livraisonLibre then livraisonLibre.onParkBrake(%d," .. tostring(electrics.values.parkingbrake or 0) .. ") end")', vid))
end

local function updateMetrics(veh, vid, dtReal, dtSim)
  local m = S.m
  if not m then return end
  local speed = S.speed or 0
  -- vitesse "stable" = minimum des derniers échantillons : élimine les pics d'un ou deux
  -- frames (reset, récupération, gros choc) qui faussaient la vitesse max
  local w = m.speedWin
  w[#w + 1] = speed
  if #w > SPEED_WINDOW then table.remove(w, 1) end
  local steady = speed
  for i = 1, #w do if w[i] < steady then steady = w[i] end end
  if (S.elapsed or 0) >= (m.ignoreUntil or 0) then
    local useSpeed = min(speed, steady + 2)
    if useSpeed > 0.2 and useSpeed < MAX_PLAUSIBLE_SPEED then
      local d = useSpeed * dtSim
      m.odo = m.odo + d
      m.segDist = m.segDist + d
    end
    if #w >= SPEED_WINDOW and steady > m.vmax and steady < MAX_PLAUSIBLE_SPEED then m.vmax = steady end
  end
  speed = steady
  if (m.stars or 0) > 0 then m.pursuitTime = m.pursuitTime + dtSim end -- temps "survécu" aux étoiles
  if not m.moveAt and speed > PERF_START_SPEED then
    m.moveAt = S.elapsed
    m.odoAtMove = m.odo
  end
  if m.moveAt and not m.nearAt and S.zoneDist < PERF_END_DIST then
    m.nearAt = S.elapsed
    m.odoAtNear = m.odo
  end
  m.dmgTimer = m.dmgTimer + dtReal
  if m.dmgTimer >= 0.25 then
    m.dmgTimer = 0
    local o = map and map.objects and map.objects[vid]
    local dmg = o and tonumber(o.damage)
    if dmg then
      if dmg < m.dmgLast - 1 then m.dmgBase = m.dmgBase + m.dmgLast end -- réparé / reset
      m.dmgLast = dmg
    end
    -- étoiles de recherche (0 à 5)
    m.stars = trafficCtl.starsFor(trafficCtl.pursuitData(vid))
    if m.stars > m.maxStars then m.maxStars = m.stars end
    if settings.traffic.progressive and (m.stars > 0 or m.policeSeen) then trafficCtl.tunePolice(vid, m.stars, 0.25) end
    if not m.policeSeen then
      local ts = trafficCtl.status()
      m.policeSeen = ts.police > 0 or (settings.traffic.mode == 'on' and settings.traffic.police ~= 'off')
    end
  end
end

local function updateWanted(dtReal)
  local w = S.wanted
  if not w then return end
  w.timer = w.timer - dtReal
  if w.timer > 0 then return end
  if trafficCtl.setWanted(S.vehId, settings.traffic.wantedLevel) then
    S.wanted = nil
    toast('warn', 'Tu es recherché : la police va te prendre en chasse !')
  else
    w.tries = w.tries + 1
    w.timer = 2
    if w.tries > 15 then S.wanted = nil end -- pas de police disponible
  end
end

local function updateDriving(dtReal, dtSim)
  local veh = S.vehId and getObjectByID(S.vehId)
  if not veh then
    S.phase = 'lost'
    S.message = 'Véhicule de livraison perdu. Monte dans un autre véhicule, ou choisis « Autre véhicule » / « Passer ».'
    clearVisuals()
    sendState()
    return
  end
  S.elapsed = S.elapsed + (dtSim or 0)
  local vid = S.vehId
  local cx, cy, cz = be:getObjectOOBBCenterXYZ(vid)
  local zone = S.zone
  local dx, dy, dz = cx - zone.x, cy - zone.y, cz - zone.z
  S.zoneDist = sqrt(dx * dx + dy * dy + dz * dz)
  local vx, vy, vz = veh:getVelocityXYZ()
  S.speed = sqrt(vx * vx + vy * vy + vz * vz)
  updateMetrics(veh, vid, dtReal, dtSim)
  updateWanted(dtReal)
  if trafficCtl.checkPoliceHit(vid) then
    S.m.policeSeen = true
    if S.m.maxStars < 1 then S.m.maxStars = 1 end
    toast('warn', 'Tu as percuté la police : 1 étoile !')
  end
  if settings.traffic.clearPoliceNearEnd and S.zoneDist < POLICE_CLEAR_DIST then
    S.policeClearTimer = (S.policeClearTimer or 0) - dtReal
    if S.policeClearTimer <= 0 then
      S.policeClearTimer = 1
      S.wanted = nil -- pas de nouvelle recherche une fois près de l'arrivée
      trafficCtl.clearPoliceNear(vid, zone, POLICE_CLEAR_DIST * 3)
    end
  end

  -- voiture garée ou PNJ arrêté sur la place : déplacé ailleurs (seulement quand le joueur est loin)
  if S.zoneDist > 60 then
    S.clearTimer = (S.clearTimer or 0) - dtReal
    if S.clearTimer <= 0 then
      S.clearTimer = 1
      local n = trafficCtl.clearZone(zone, {[vid] = true, [be:getPlayerVehicleID(0)] = true})
      if n > 0 then log('I', logTag, n .. ' véhicule(s) déplacé(s) hors de la place de livraison') end
    end
  end

  if S.zoneDist < max(40, zone.l * 2) then
    S.inZone = vehicleInZone(vid, zone)
    S.pbTimer = S.pbTimer + dtReal
    if S.pbTimer >= 0.15 then
      S.pbTimer = 0
      pollParkBrake(veh, vid)
    end
  else
    S.inZone = false
  end

  local required = (settings.validation == 'auto') and 3.0 or (settings.instantNext and 0.25 or 0.6)
  local ok = S.inZone and S.speed < 0.5
  if ok and settings.validation ~= 'auto' then ok = (S.parkBrake or 0) >= 0.5 end
  if ok then
    S.validateTimer = S.validateTimer + dtSim
  else
    S.validateTimer = 0
  end
  S.validate = clamp(S.validateTimer / required, 0, 1)
  if S.validateTimer >= required then
    deliver()
    return
  end

  if S.timeLimit and perfTime() > S.timeLimit then
    failMission('Temps écoulé')
  end
end

local function hudData()
  local m = S.m
  local d = {phase = S.phase, elapsed = perfTime(), total = S.elapsed, count = S.count}
  d.chronoState = (not m or not m.moveAt) and 'wait' or (m.nearAt and 'stopped' or 'running')
  if S.timeLimit then d.timeLeft = S.timeLimit - perfTime() end
  if S.phase == 'driving' and S.zone then
    local rem = 0
    local gm = core_groundMarkers
    if gm and gm.currentlyHasTarget and gm.currentlyHasTarget() and gm.getPathLength then
      local ok, v = pcall(gm.getPathLength)
      if ok and type(v) == 'number' then rem = v end
    end
    if rem <= 0 or S.zoneDist < 30 then rem = S.zoneDist end
    d.distLeft = rem
    d.progress = clamp(1 - rem / max(S.routeDist or 1, 1), 0, 1)
    d.inZone = S.inZone
    d.parkBrake = (S.parkBrake or 0) >= 0.5
    d.speedKmh = (S.speed or 0) * 3.6
    d.validate = S.validate
    d.near = S.zoneDist < 60
    d.inVehicle = be:getPlayerVehicleID(0) == S.vehId
    d.validation = settings.validation
    if m then
      d.odo = m.odo
      d.avgKmh = perfAvgKmh()
      d.parkTime = m.nearAt and ((S.elapsed or 0) - m.nearAt) or nil
      d.vmaxKmh = m.vmax * 3.6
      d.resets = m.resets
      d.damage = floor(m.dmgBase + m.dmgLast + 0.5)
      d.switches = m.switches
      d.pursuits = m.pursuits
      d.pursuitTime = m.pursuitTime
    end
    d.pursuit = trafficCtl.pursuitMode(S.vehId)
    d.stars = m and m.stars or 0
    d.policeOn = m and m.policeSeen or false
    local ts = trafficCtl.status()
    d.traffic = {active = ts.active, amount = ts.amount, parked = ts.parked, police = ts.police}
  end
  return d
end

---------------------------------------------------------------------------
-- hooks
---------------------------------------------------------------------------
local function onUpdate(dtReal, dtSim, dtRaw)
  if analysis then stepAnalysis() end
  if not S then return end
  dtReal = dtReal or 0
  if S.phase == 'fading' then
    S.phaseTimer = S.phaseTimer + dtReal
    if S.blackReached or S.phaseTimer >= 1.4 then safeCall(doSpawn, 'spawn') end
  elseif S.phase == 'spawning' then
    S.phaseTimer = S.phaseTimer + dtReal
    local trafficOk = not S.waitTraffic or trafficCtl.isReady() or S.phaseTimer >= 25
    if S.phaseTimer >= 0.5 and trafficOk then safeCall(beginDriving, 'demarrage') end
  elseif S.phase == 'driving' then
    if S.ffbRelease then
      S.ffbRelease = S.ffbRelease - dtReal
      if S.ffbRelease <= 0 then S.ffbRelease = nil; releaseAllFFB() end
    end
    if S.pendingSummary and S.summaryDelay then
      S.summaryDelay = S.summaryDelay - dtReal
      if S.summaryDelay <= 0 then flushSummary() end
    end
    local ok, err = pcall(updateDriving, dtReal, dtSim or 0)
    if not ok then log('E', logTag, 'update : ' .. tostring(err)) end
  elseif S.phase == 'summary' or S.phase == 'failed' then
    S.phaseTimer = S.phaseTimer + dtReal
    local wait = (S.phase == 'summary') and 3.5 or 4.5
    if settings.autoNext and S.phaseTimer >= wait then prepareNext({}) end
  end

  if S then
    S.sirenTimer = (S.sirenTimer or 0) - dtReal
    if S.sirenTimer <= 0 then
      S.sirenTimer = 2
      trafficCtl.updateSirenPatches(settings.traffic.civiliansIgnoreSirens, settings.traffic.policeNoSiren)
    end
    hudTimer = hudTimer + dtReal
    if hudTimer >= 0.2 then
      hudTimer = 0
      guihooks.trigger('LivraisonLibreHud', hudData())
    end
  end
end

local function onPreRender(dtReal, dtSim, dtRaw)
  if not S or not S.zone then return end
  if S.phase ~= 'driving' and S.phase ~= 'summary' then return end
  local zone = S.zone
  if not decalTbl then
    decalPos, decalFwd, decalScale = vec3(), vec3(), vec3()
    colRed, colBlue, colGreen = ColorF(0.86, 0.17, 0.15, 0.95), ColorF(0.12, 0.45, 1.0, 0.95), ColorF(0.15, 0.85, 0.35, 0.95)
    decalTbl = {{texture = DECAL_TEXTURE, position = decalPos, forwardVec = decalFwd, color = colRed, scale = decalScale, fadeStart = 250, fadeEnd = 400}}
  end
  decalPos:set(zone.x, zone.y, zone.z)
  decalFwd:set(zone.fx, zone.fy, zone.fz)
  decalScale:set(zone.w, zone.l, 1)
  local col = colRed
  if S.phase == 'summary' then col = colGreen elseif S.inZone then col = colBlue end
  decalTbl[1].color = col
  pcall(Engine.Render.DynamicDecalMgr.addDecals, decalTbl, 1)

  -- repère vertical de 2 m au centre de la place (même couleur que la zone)
  if settings.showCenterPost then pcall(function()
    local base, top = vec3(zone.x, zone.y, zone.z), vec3(zone.x, zone.y, zone.z + CENTER_POST_HEIGHT)
    debugDrawer:drawCylinder(base, top, 0.05, col)
    debugDrawer:drawSphere(top, 0.13, col)
  end) end

  if S.phase == 'driving' then
    -- colonne lumineuse visible de loin
    local d = S.zoneDist or 0
    if settings.showBeam and d > 45 then
      local alpha = clamp((d - 45) / 120, 0, 1) * 0.28
      pcall(function()
        debugDrawer:drawCylinder(vec3(zone.x, zone.y, zone.z), vec3(zone.x, zone.y, zone.z + 60), 0.7, ColorF(0.95, 0.3, 0.2, alpha))
      end)
    end
    if marker then
      local ok = pcall(marker.update, marker, dtReal, dtSim)
      if not ok then removeMarker() end
    end
  end
end

local function onScreenFadeState(state)
  if S and S.phase == 'fading' and state == 1 then S.blackReached = true end
end

local function onVehicleDestroyed(vid)
  if not S then return end
  if S.expectDelete and S.expectDelete[vid] then S.expectDelete[vid] = nil return end
  if vid == S.vehId and S.phase == 'driving' then
    S.vehId = nil
  end
end

local function onClientPostStartMission()
  levelData = nil
  analysis, startPending = nil, false
  analysisErrors = 0
  if S then stopSession(true) end
  sendState()
end

local function onClientEndMission()
  levelData = nil
  analysis, startPending = nil, false
  if S then stopSession() end
end

local function onNavgraphReloaded()
  if not S then levelData = nil; analysis = nil end
end

local function onExtensionLoaded()
  loadData()
  math.randomseed(os.time())
  log('I', logTag, 'Livraison Libre ' .. VERSION .. ' chargé (' .. #journalRecords .. ' livraisons au journal)')
end

local function onExtensionUnloaded()
  if S and S.faded then endFade() end
  releaseAllFFB()
  clearVisuals()
end

-- R / Inser / Origine (reset, récupération) sur le véhicule de livraison
local function trackVehReset()
  if S and S.phase == 'driving' and S.m and be:getPlayerVehicleID(0) == S.vehId then
    S.m.resets = S.m.resets + 1
    pauseMeasures(1.5)
  end
end

local function onPursuitAction(id, action, data)
  if not S or not S.m or id ~= S.vehId then return end
  if action == 'start' then
    S.m.pursuits = S.m.pursuits + 1
    -- mode recherché : la poursuite démarre au nombre d'étoiles choisi
    if settings.traffic.mode == 'on' and settings.traffic.police == 'wanted' and type(data) == 'table' then
      local target = trafficCtl.STAR_SCORES[settings.traffic.wantedLevel] or 0
      if (tonumber(data.score) or 0) < target then data.score = target end
    end
    if type(data) == 'table' then
      local st = trafficCtl.starsFor({mode = math.max(1, tonumber(data.mode) or 0), score = data.score})
      if st > S.m.maxStars then S.m.maxStars = st end
      S.m.policeSeen = true
    end
  elseif action == 'arrest' then
    S.m.arrests = S.m.arrests + 1
    if settings.traffic.arrestFails and S.phase == 'driving' then failMission('Arrêté par la police') end
  elseif action == 'evade' then
    toast('ok', 'Police semée !')
  end
end

local function onPursuitModeUpdate(id, data)
  if not S or not S.m or id ~= S.vehId or type(data) ~= 'table' or (tonumber(data.mode) or 0) < 1 then return end
  local st = trafficCtl.starsFor(trafficCtl.pursuitData(id) or {mode = data.mode, score = 0})
  if st > S.m.maxStars then S.m.maxStars = st end
  S.m.policeSeen = true
end

local function onTrafficOrParkingReady()
  trafficCtl.onReady()
  sendState()
end

---------------------------------------------------------------------------
-- API appelée par l'interface
---------------------------------------------------------------------------
function M.requestState() sendState() end

function M.requestMapInfo()
  analyzeLevel(function(ld, err)
    if not ld and err then toast('warn', err) end
  end)
end

function M.setSettings(newSettings)
  if type(newSettings) ~= 'table' then return end
  if S then toast('warn', 'Les réglages sont verrouillés pendant les livraisons.') sendState() return end
  local ui = copyTable(settings.ui)
  mergeInto(settings, newSettings, DEFAULTS)
  settings.ui = ui -- l'état de l'interface a sa propre fonction
  sanitizeSettings(settings)
  saveSettings()
  sendState()
end

function M.setUiPrefs(prefs)
  if type(prefs) ~= 'table' then return end
  mergeInto(settings.ui, prefs, DEFAULTS.ui)
  sanitizeSettings(settings)
  saveSettings()
end

function M.resetSettings()
  if S then return end
  local bl, ui = settings.veh.blacklist, settings.ui
  settings = copyTable(DEFAULTS)
  settings.veh.blacklist, settings.ui = bl, ui
  saveSettings()
  sendState()
end

function M.requestVehicles()
  local pool = ensurePool()
  if pool then ensureTransmissions() end
  guihooks.trigger('LivraisonLibreVehicles', {models = pool and vehLib.modelSummaries(pool, settings.veh) or {}})
  sendState()
end

function M.setBlacklisted(modelKey, banned)
  if type(modelKey) ~= 'string' then return end
  settings.veh.blacklist[modelKey] = banned and true or nil
  saveSettings()
  sendState()
end

function M.clearBlacklist()
  settings.veh.blacklist = {}
  saveSettings()
  M.requestVehicles()
end

function M.start()
  if S then return end
  local lvl = levelName()
  if not lvl then toast('err', 'Charge une map en freeroam pour lancer une livraison.') return end
  if not (levelData and levelData.name == lvl) then
    -- analyse de la map d'abord (étalée sur plusieurs images), puis lancement
    if startPending then return end
    startPending = true
    analyzeLevel(function(ld, err)
      startPending = false
      if ld then M.start() elseif err then toast('err', err) end
    end)
    return
  end
  if not ensurePool() then toast('err', 'Impossible de lire la liste des véhicules.') return end
  S = newSession()
  S.trafficPending = settings.traffic.mode ~= 'keep'
  prepareNext({})
end

function M.stop()
  if not S then return end
  stopSession()
  ui_message('Livraison Libre arrêté.', 3, 'livraisonLibre', 'info')
end

function M.toggle()
  if S then M.stop() else M.start() end
end

-- Abandonne la mission en cours et passe à la suivante (nouveau véhicule + téléport)
function M.skip()
  if not S or S.phase == 'fading' or S.phase == 'spawning' then return end
  if S.phase == 'driving' or S.phase == 'lost' then
    recordMission('Passée')
    stats.skipped = (stats.skipped or 0) + 1
    stats.streak = 0
    saveStats()
  end
  trafficCtl.resetPursuit(S.vehId)
  prepareNext({})
end

function M.next()
  if not S then return end
  if S.phase == 'summary' or S.phase == 'failed' then prepareNext({}) end
end

-- Nouvelle destination depuis la position actuelle, même véhicule
function M.rerollDestination()
  if not S or S.phase ~= 'driving' then return end
  local veh = S.vehId and getObjectByID(S.vehId)
  if not veh then return end
  local plan, err = planMission(S.vehW or 2, S.vehL or 4.8, true)
  if not plan then toast('err', err) return end
  recordMission('Destination changée')
  stats.skipped = (stats.skipped or 0) + 1
  stats.streak = 0
  saveStats()
  clearVisuals()
  S.plan = plan
  S.plan.pickup = nil
  safeCall(beginDriving, 'nouvelle destination')
end

-- Remplace le véhicule sur place (même destination, même chrono)
function M.rerollVehicle()
  if not S or (S.phase ~= 'driving' and S.phase ~= 'lost') or not S.dest then return end
  local info, err = pickVehicleInfo()
  if not info then toast('err', err) return end
  local prevPhase = S.phase
  closeSegment()
  S.phase = 'spawning'           -- ignore les hooks de changement de véhicule pendant notre remplacement
  local ok = safeCall(function()
    local cur = S.vehId and getObjectByID(S.vehId)
    local veh
    if cur then
      veh = core_vehicles.replaceVehicle(info.model, spawnOptions(info), cur)
    else
      veh = core_vehicles.spawnNewVehicle(info.model, spawnOptions(info))
    end
    if not veh then error('remplacement impossible') end
    if cur and veh:getID() ~= S.vehId then deleteVehicle(S.vehId) end
    S.vehId = veh:getID()
    S.info = info
    table.insert(S.recent, info.model)
    S.plan = {dest = S.dest, destZone = S.zone, pickup = S.pickup, dist = S.routeDist, relaxed = S.relaxed}
    S.phaseTimer = 0
    S.keepTimer = {elapsed = S.elapsed, limit = S.timeLimit}
  end, 'changement de vehicule')
  if not ok and S then S.phase = prevPhase end
  if S then sendState() end
end

function M.banCurrentModel()
  if not S or not S.info then return end
  settings.veh.blacklist[S.info.model] = true
  saveSettings()
  toast('info', (S.info.modelName or S.info.model) .. ' ajouté à la liste noire.')
  M.rerollVehicle()
end

function M.onParkBrake(vid, value)
  if S and vid == S.vehId then S.parkBrake = tonumber(value) or 0 end
end

-- trafic
function M.applyTrafficNow()
  if S then return end
  local res, msg = trafficCtl.apply(settings.traffic, levelName())
  if msg then toast(res == 'error' and 'err' or 'warn', msg)
  elseif res == 'skipped' then toast('info', 'Mode « Ne pas toucher » : le trafic actuel est conservé.')
  else toast('ok', settings.traffic.mode == 'off' and 'Trafic retiré.' or 'Trafic en cours de création…') end
  sendState()
end

function M.removeTrafficNow()
  if S then return end
  trafficCtl.removeAll()
  toast('ok', 'Trafic et voitures garées retirés.')
  sendState()
end

-- aperçu de l'écran de résumé (pour le placer dans l'interface)
function M.previewSummary()
  -- image et nom du véhicule actuel du joueur si possible
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  local okI, info = false, nil
  if veh then okI, info = pcall(infoFromVehicle, veh) end
  if not okI or type(info) ~= 'table' then info = nil end
  guihooks.trigger('LivraisonLibreSummary', {
    ok = true, isPreview = true, count = 12, showFor = 10,
    preview = info and info.preview or nil,
    vehicle = info and info.name or 'ETK 800-Series 856x Sport', from = 'Parking', to = 'Station-service',
    tripTime = 184, totalTime = 207, parkTime = 15, plannedDist = 2350, tripDist = 2290, driven = 2410,
    avgKmh = 44.8, vmaxKmh = 96, resets = 1, damage = 350, switches = 0, pursuits = 0, arrests = 0,
    records = {avg = true}, streak = 4, maxStars = 3, policeActive = true, pursuitTime = 97,
  })
end

-- journal
function M.openDataFolder()
  ensureDir(DATA_DIR)
  if Engine and Engine.Platform and Engine.Platform.exploreFolder then
    pcall(Engine.Platform.exploreFolder, DATA_DIR)
  end
end

-- points perso
function M.addPoint(name)
  local lvl = levelName()
  if not lvl then toast('err', 'Aucune map chargée.') return end
  local veh = getPlayerVehicle(0)
  local pos, dir
  if veh then
    local vid = veh:getID()
    local cx, cy, cz = be:getObjectOOBBCenterXYZ(vid)
    local d = veh:getDirectionVector()
    pos = {x = cx, y = cy, z = groundZ(cx, cy, cz)}
    dir = {x = d.x, y = d.y, z = d.z}
  else
    local p = core_camera.getPosition()
    local q = core_camera.getQuat() * vec3(0, 1, 0)
    pos = {x = p.x, y = p.y, z = groundZ(p.x, p.y, p.z - 1.5)}
    dir = {x = q.x, y = q.y, z = 0}
  end
  local points = getPoints(lvl)
  local id = 0
  for _, p in ipairs(points) do id = max(id, tonumber(p.id) or 0) end
  id = id + 1
  if type(name) ~= 'string' or name:gsub('%s', '') == '' then name = 'Point ' .. id end
  points[#points + 1] = {id = id, name = name:sub(1, 40), pos = pos, dir = dir, created = os.date('%Y-%m-%d %H:%M')}
  savePoints(lvl)
  toast('ok', 'Point « ' .. name:sub(1, 40) .. ' » enregistré.')
  sendState()
end

function M.removePoint(id)
  local lvl = levelName()
  local points = getPoints(lvl)
  for i = #points, 1, -1 do
    if points[i].id == id then table.remove(points, i) end
  end
  savePoints(lvl)
  sendState()
end

function M.renamePoint(id, name)
  if type(name) ~= 'string' or name:gsub('%s', '') == '' then return end
  local lvl = levelName()
  for _, p in ipairs(getPoints(lvl)) do
    if p.id == id then p.name = name:sub(1, 40) end
  end
  savePoints(lvl)
  sendState()
end

function M.teleportToPoint(id)
  if S then toast('warn', "Arrête la livraison en cours avant de te téléporter.") return end
  local veh = getPlayerVehicle(0)
  if not veh then return end
  for _, p in ipairs(getPoints()) do
    if p.id == id then
      local rot = quatFromDir(vec3(p.dir.x, p.dir.y, p.dir.z), vec3(0, 0, 1))
      spawn.safeTeleport(veh, vec3(p.pos.x, p.pos.y, p.pos.z + 0.3), rot, nil, nil, nil, true)
      return
    end
  end
end

function M.routeToPoint(id)
  if S then return end
  for _, p in ipairs(getPoints()) do
    if p.id == id then
      local gm = ensureExt('core_groundMarkers')
      if gm then pcall(gm.setPath, vec3(p.pos.x, p.pos.y, p.pos.z), {clearPathOnReachingTarget = true}) end
      return
    end
  end
end

function M.resetStats()
  stats = copyTable(STATS_DEFAULTS)
  saveStats()
  sendState()
end

function M.toggleUI()
  guihooks.trigger('LivraisonLibreToggle', {})
end

function M.getDebugInfo()
  return {level = levelData and levelData.name, nodes = levelData and levelData.g.n, cands = levelData and #levelData.cands,
          session = S and S.phase, journal = #journalRecords, traffic = trafficCtl.status()}
end

M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onScreenFadeState = onScreenFadeState
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleSwitched = function(oldId, newId, player)
  if (player or 0) == 0 and S and newId ~= S.vehId then vehicleChanged(newId) end
end
M.onVehicleReplaced = function(vid) if S and vid == S.vehId then vehicleChanged(vid) end end
M.onVehicleSpawned = function(vid) if S and vid == S.vehId then vehicleChanged(vid) end end
M.trackVehReset = trackVehReset
M.onPursuitAction = onPursuitAction
M.onPursuitModeUpdate = onPursuitModeUpdate
M.onTrafficOrParkingReady = onTrafficOrParkingReady
M.onClientPostStartMission = onClientPostStartMission
M.onClientEndMission = onClientEndMission
M.onNavgraphReloaded = onNavgraphReloaded
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onModActivated = function() vehPool = nil; badModels = {} end
M.onModDeactivated = function() vehPool = nil; badModels = {} end

-- Garde-fou : aucune erreur interne ne remonte au jeu (pas de grosse erreur à l'écran ni de
-- spam chaque frame). Elle est écrite dans la console (3 fois max par fonction) avec sa pile
-- d'appels, et signalée une seule fois par un petit message dans l'app.
local guardCount = {}
local function guard(name, fn)
  return function(...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if ok then return err end
    guardCount[name] = (guardCount[name] or 0) + 1
    if guardCount[name] <= 3 then log('E', logTag, 'Erreur interne (' .. name .. ') : ' .. tostring(err)) end
    if guardCount[name] == 1 then
      pcall(guihooks.trigger, 'LivraisonLibreToast', {kind = 'err', msg = 'Livraison Libre : erreur interne (' .. name .. '). Détails dans la console (~).'})
    end
  end
end
for k, fn in pairs(M) do
  if type(fn) == 'function' and k ~= 'getDebugInfo' then M[k] = guard(k, fn) end
end

return M
