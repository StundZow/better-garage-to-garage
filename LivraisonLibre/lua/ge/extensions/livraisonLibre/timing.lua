-- Livraison Libre - temps limite selon la difficulté
-- Estime le temps qu'il faut pour faire le trajet avec un véhicule donné, à partir de ses performances
-- (0-100 km/h, vitesse max, freinage, hauteur) et du trajet (virages, carrefours, pentes, limitations, largeur, terre)
-- et du trafic, pour un conducteur allant du débutant (très facile) au pilote (impossible). Simulation d'un
-- profil de vitesse : vitesse max autorisée par les virages, les carrefours et la route, puis accélération et
-- freinage réalistes.
-- Module "pur" (nombres uniquement), testable hors du jeu.

local M = {}

local sqrt, min, max, abs, atan2, log, pi, huge = math.sqrt, math.min, math.max, math.abs, math.atan2, math.log, math.pi, math.huge
local G = 9.81
local STEP = 5          -- m : pas de la simulation
local WINDOW = 2        -- pas de part et d'autre pour mesurer la courbure (±10 m)
local ROAD_WIDTH = 8    -- m : largeur d'une route normale à double sens (référence)
local JUNCTION_R = 10   -- m : ralentissement autour d'un carrefour
local JUNCTION_MERGE = 30 -- m : carrefours plus proches = un seul (gros carrefour à plusieurs noeuds)
local TOWN_GAP = 220    -- m : carrefours à moins de 220 m les uns des autres = en ville
local TOWN_R = 120      -- m : la ville s'étend à 120 m autour de ces carrefours
local FAST_LIMIT = 22.2 -- m/s : 80 km/h
local MAX_SLOPE = 0.35  -- pente (sinus) maximale prise en compte : au-delà, donnée douteuse (pont, tunnel)
local V_CRAWL = 4       -- m/s : côte trop raide pour le moteur, on monte quand même au pas (en première)
-- Trafic : peut-on passer entre deux voitures (la sienne et celle d'à côté, chacune au milieu de sa voie)
-- avec une vraie marge, ou faut-il se rabattre derrière et attendre de pouvoir doubler ?
local TRAFFIC_W = 2.0   -- m : largeur d'une voiture du trafic
local PASS_MARGIN = 0.5 -- m : marge de chaque côté pour passer entre deux voitures (pas « au millimètre »)
local LANE_W = 3.6      -- m : largeur d'une voie quand la map ne donne pas le nombre de voies
-- part du temps perdu derrière le trafic selon la route (multipliée par la densité et l'écart de vitesse)
local BLOCK = {squeeze = 0.05, lanes = 0.12, twoWay = 0.20, twoWayTown = 0.30, oneLane = 0.45}

-- limit : facteur sur la limitation de vitesse
-- wgain : effet de la largeur de la route sur ce facteur (route large : plus vite, route étroite : moins vite)
-- free : part de « je roule à la vitesse que la route permet » plutôt qu'à la limitation (0 à 1)
-- grip / accel / brake : part de l'adhérence, de l'accélération et du freinage du véhicule utilisée
-- line : trajectoire (1 = reste au milieu de sa voie ; plus = utilise la largeur, coupe les virages)
-- En ville (carrefours rapprochés) : town = part du dépassement de la limitation gardée, tfree = part de
-- « vitesse que la route permet », jn = vitesse de passage d'un carrefour (km/h).
-- down : prudence en descente raide (on lève le pied au-delà de 4 % de pente).
-- park : temps pour les 50 derniers mètres et le stationnement, quand le chrono va jusqu'à la validation.
-- margin : marge sur le temps simulé
M.LEVELS = {
  {id = 'tres_facile', label = 'Très facile',    limit = 0.9, wgain = 0.06, free = 0,    grip = 0.40, accel = 0.45, brake = 0.40, line = 1.05,
   town = 1,    tfree = 0,    jn = 26, down = 2.0, park = 40, margin = 1.45},
  {id = 'facile',      label = 'Facile',         limit = 1.0, wgain = 0.08, free = 0,    grip = 0.50, accel = 0.55, brake = 0.50, line = 1.08,
   town = 1,    tfree = 0,    jn = 32, down = 1.6, park = 32, margin = 1.25},
  {id = 'moyen',       label = 'Moyen',          limit = 1.2, wgain = 0.17, free = 0.05, grip = 0.65, accel = 0.75, brake = 0.65, line = 1.15,
   town = 0.7,  tfree = 0,    jn = 42, down = 1.2, park = 25, margin = 1.12},
  {id = 'dur',         label = 'Difficile',      limit = 1.5, wgain = 0.33, free = 0.15, grip = 0.80, accel = 0.90, brake = 0.80, line = 1.35,
   town = 0.65, tfree = 0,    jn = 55, down = 0.8, park = 20, margin = 1.05},
  {id = 'tres_dur',    label = 'Très difficile', limit = 1.9, wgain = 0.47, free = 0.35, grip = 0.92, accel = 1.0,  brake = 0.92, line = 1.6,
   town = 0.65, tfree = 0.1,  jn = 65, down = 0.5, park = 16, margin = 1.0},
  {id = 'impossible',  label = 'Impossible',     limit = 2.0, wgain = 0.5,  free = 1,    grip = 1.05, accel = 1.0,  brake = 1.0,  line = 2.0,
   town = 0.55, tfree = 0.3,  jn = 78, down = 0.2, park = 12, margin = 0.95},
}
M.byId = {}
for i, l in ipairs(M.LEVELS) do l.index = i; M.byId[l.id] = l end

local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function num(v) v = tonumber(v); if v and v == v and v > -huge and v < huge then return v end return nil end

-- valeurs par défaut selon la catégorie quand la config ne donne pas ses performances (mods)
local DEFAULTS = {
  camion =      {top = 27, z100 = 30, brakeG = 0.75, height = 3.2},
  bus =         {top = 27, z100 = 40, brakeG = 0.75, height = 3.0},
  engin =       {top = 12, z100 = nil, brakeG = 0.6, height = 3.5},
  utilitaire =  {top = 40, z100 = 15, brakeG = 0.85, height = 2.3},
  pickup =      {top = 48, z100 = 9,  brakeG = 0.9,  height = 1.9},
  suv =         {top = 50, z100 = 9,  brakeG = 0.9,  height = 1.8},
  toutterrain = {top = 40, z100 = 8,  brakeG = 0.8,  height = 1.8},
  sport =       {top = 75, z100 = 5,  brakeG = 1.15, height = 1.25},
  default =     {top = 55, z100 = 9,  brakeG = 0.95, height = 1.45},
}

-- Modèle du véhicule. perf = {top (m/s), z100 (s), power (kW), weight (kg), brakeG, height (m),
-- drive ('RWD' | 'FWD' | 'AWD'...), cfgType ('Drift'...), offroad (score tout-terrain du jeu)}
function M.vehicleModel(perf, mainCat)
  perf = perf or {}
  local d = DEFAULTS[mainCat or ''] or DEFAULTS.default
  local vt = num(perf.top)
  if not vt or vt < 5 or vt > 150 then vt = d.top end
  -- accélération : a(v) = A (1 - (v/vt)²), avec A calé pour retrouver le 0-100 km/h annoncé
  local A
  local t100 = num(perf.z100) or d.z100
  if t100 and t100 > 0.8 and t100 < 120 and vt > 28.5 then
    A = vt / (2 * t100) * log((vt + 27.78) / (vt - 27.78))
  else
    local P, m = num(perf.power), num(perf.weight)
    if P and m and m > 0 then A = P * 1000 * 0.75 / (m * 12) else A = 1.5 end
  end
  A = clamp(A, 0.3, 14)
  local bg = num(perf.brakeG)
  if not bg or bg < 0.3 or bg > 2.5 then bg = d.brakeG end
  local h = num(perf.height)
  if not h or h < 0.6 or h > 6 then h = d.height end
  local heightFactor = clamp(1.25 - 0.25 * h, 0.5, 1) -- un véhicule haut prend les virages moins vite
  -- comportement : de « drifteuse » (propulsion très puissante pour son poids, config de drift) à
  -- « accrocheuse » (4 roues motrices). stab : part de l'adhérence vraiment exploitable en virage ;
  -- share : part du poids sur les roues motrices (motricité à l'accélération)
  local P, m = num(perf.power), num(perf.weight)
  local pw = (P and m and m > 0) and (P * 1000 / m) or 0 -- W/kg
  local drive = type(perf.drive) == 'string' and perf.drive:upper() or ''
  local share, stab
  if drive:find('AWD', 1, true) or drive:find('4WD', 1, true) then
    share, stab = 0.95, 1 - 0.05 * clamp((pw - 200) / 200, 0, 1)
  elseif drive:find('FWD', 1, true) then
    share, stab = 0.55, 0.97 - 0.10 * clamp((pw - 110) / 150, 0, 1)
  elseif drive:find('RWD', 1, true) then
    share, stab = 0.6, 0.95 - 0.30 * clamp((pw - 90) / 200, 0, 1)
  else
    share, stab = 0.6, 0.95 - 0.20 * clamp((pw - 90) / 200, 0, 1)
  end
  if type(perf.cfgType) == 'string' and perf.cfgType:lower():find('drift', 1, true) then stab = min(stab, 0.72) end
  stab = clamp(stab, 0.6, 1)
  -- pneus tout-terrain : moins d'adhérence perdue sur la terre
  local dirt = 0.55 + 0.25 * clamp(((num(perf.offroad) or 30) - 30) / 50, 0, 1)
  return {vt = vt, A = A, aBrk = bg * G, aLat = 0.9 * bg * G * heightFactor * (1 - (1 - stab) * 0.35),
    stab = stab, share = share, dirt = dirt}
end

-- Carrefours du trajet (points où au moins 3 routes se rejoignent), regroupés, et ceux « en ville »
-- (un autre carrefour à moins de TOWN_GAP). Renvoie deux listes de positions le long du trajet (m).
local function junctions(points)
  local all, s = {}, 0
  for i = 1, #points do
    if i > 1 then
      local a, b = points[i - 1], points[i]
      s = s + sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
    end
    -- jn : vrai carrefour d'après graph.route (pas une bretelle d'autoroute) ; sinon, d'après deg
    local isJn
    if points[i].jn ~= nil then isJn = points[i].jn else isJn = (tonumber(points[i].deg) or 0) >= 3 end
    if i > 1 and i < #points and isJn then
      if not all[1] or s - all[#all] > JUNCTION_MERGE then all[#all + 1] = s end
    end
  end
  local town = {}
  for i, js in ipairs(all) do
    if (all[i - 1] and js - all[i - 1] <= TOWN_GAP) or (all[i + 1] and all[i + 1] - js <= TOWN_GAP) then
      town[#town + 1] = js
    end
  end
  return town
end

-- Rééchantillonne le trajet tous les STEP mètres (sans les trimEnd derniers mètres).
-- Chaque point : cap, limitation, état, largeur, et s'il est en ville / dans un carrefour de ville.
local function resample(points, trimEnd)
  local segs, total = {}, 0
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len > 0.01 then
      segs[#segs + 1] = {a = a, len = len, s0 = total, dx = dx / len, dy = dy / len, heading = atan2(dy, dx),
        slope = clamp(dz / len, -MAX_SLOPE, MAX_SLOPE)}
      total = total + len
    end
  end
  local length = total - (trimEnd or 0)
  if #segs == 0 or length < STEP * 2 then return nil, max(0, length) end
  local town = junctions(points)
  local samples, k, si, ji = {}, 0, 1, 1
  local s = 0
  while s <= length do
    while si < #segs and segs[si].s0 + segs[si].len < s do si = si + 1 end
    local sg = segs[si]
    k = k + 1
    -- carrefour de ville le plus proche (liste triée : on avance au fur et à mesure)
    while town[ji + 1] and abs(town[ji + 1] - s) <= abs(town[ji] - s) do ji = ji + 1 end
    local dj = town[ji] and abs(town[ji] - s) or huge
    samples[k] = {heading = sg.heading, speed = sg.a.speed, drv = sg.a.drv, width = sg.a.r and sg.a.r * 2 or nil, slope = sg.slope,
      lanes = sg.a.lanes, oneWay = sg.a.oneWay, town = dj <= TOWN_R, junction = dj <= JUNCTION_R}
    s = s + STEP
  end
  return samples, length
end

local function wrap(a)
  while a > pi do a = a - 2 * pi end
  while a < -pi do a = a + 2 * pi end
  return a
end

-- Route et trafic : part du temps perdu derrière les voitures (BLOCK) selon la largeur des voies et celle
-- du véhicule. w : largeur de la route (m), lanes : nombre de voies (0 = inconnu), vehW : largeur du véhicule.
function M.trafficBlock(w, lanes, oneWay, vehW, town)
  w = clamp(tonumber(w) or ROAD_WIDTH, 2.5, 30)
  lanes = tonumber(lanes) or 0
  if lanes < 1 then lanes = max(1, math.floor(w / LANE_W + 0.3)) end
  local laneW = w / lanes
  local need = (tonumber(vehW) or 1.9) + 2 * PASS_MARGIN
  -- passer au milieu : entre deux voitures de voies voisines (sur une seule voie : à côté de la voiture)
  local gap = (lanes >= 2) and (laneW - TRAFFIC_W) or ((laneW - TRAFFIC_W) * 0.5)
  if gap >= need then return BLOCK.squeeze end
  local sameDir = oneWay and lanes or math.floor(lanes / 2)
  if sameDir >= 2 then return BLOCK.lanes end      -- on change de voie pour doubler
  if oneWay then return BLOCK.oneLane end          -- une seule voie : coincé derrière
  return town and BLOCK.twoWayTown or BLOCK.twoWay -- on double quand la voie d'en face est libre
end

-- Densité du trafic (0 : route vide ; 1 : trafic habituel d'une dizaine de véhicules) d'après leur nombre
function M.trafficDensity(amount)
  amount = tonumber(amount)
  if not amount or amount ~= amount or amount <= 0 then return 0 end
  return clamp(amount / 10, 0, 1.5)
end

-- Temps estimé (s) pour parcourir le trajet. points : graph.route() ; veh : vehicleModel() ; level : id.
-- opts.trimEnd : mètres non chronométrés à la fin (le chrono s'arrête à 50 m de la zone).
-- opts.traffic : densité du trafic (M.trafficDensity) : on suit les autres, on croise aux carrefours.
-- opts.vehW : largeur du véhicule (m), pour savoir s'il passe entre les voitures du trafic.
function M.estimate(points, veh, level, opts)
  opts = opts or {}
  local L = M.byId[level] or M.byId.moyen
  if type(points) ~= 'table' or #points < 2 or not veh then return nil end
  local traffic = clamp(tonumber(opts.traffic) or 0, 0, 1.5)
  local vehW = clamp(tonumber(opts.vehW) or 1.9, 1, 4)
  local smp, length = resample(points, opts.trimEnd or 50)
  if not smp then
    -- trajet très court : départ arrêté, accélération seulement
    return max(5, sqrt(2 * max(length, 1) / max(0.5, veh.A * L.accel))) * L.margin
  end
  local n = #smp
  local vmax = {}
  for k = 1, n do
    local hA = smp[max(1, k - WINDOW)].heading
    local hB = smp[min(n, k + WINDOW)].heading
    local span = (min(n, k + WINDOW) - max(1, k - WINDOW)) * STEP
    local curv = span > 0 and abs(wrap(hB - hA)) / span or 0
    local drv = clamp(tonumber(smp[k].drv) or 1, 0, 1)
    local dirt = veh.dirt or 0.55
    local gs = dirt + (1 - dirt) * drv -- terre / route dégradée : moins d'adhérence (moins avec des pneus tout-terrain)
    local grip = L.grip * gs
    smp[k].grip, smp[k].gs = grip, gs
    -- largeur de la route : couper un virage demande de la place (rayon gagné selon la largeur),
    -- et une route large permet de rouler plus vite qu'une petite route étroite
    local w = clamp(tonumber(smp[k].width) or ROAD_WIDTH, 2.5, 30)
    local line = 1 + ((L.line or 1) - 1) * clamp(w / ROAD_WIDTH, 0.4, 1.6)
    local vc = curv > 1e-4 and sqrt(veh.aLat * grip * line / curv) or huge
    -- pour le cercle d'adhérence : virage pris (courbure) et adhérence latérale totale du véhicule ici
    smp[k].curv, smp[k].latCap = curv, veh.aLat * gs * line
    local limit = tonumber(smp[k].speed)
    if not limit or limit <= 0 or limit > 80 then limit = 22.2 end
    -- vitesse visée par rapport à la limitation : plus haute sur une route large, plus basse sur une petite route
    local over = L.limit * (1 + L.wgain * (clamp(w / ROAD_WIDTH, 0.5, 1.5) - 1))
    local free = L.free
    if smp[k].town then
      -- en ville : carrefours, piétons, sorties de parkings... on dépasse moins la limitation
      over = 1 + (over - 1) * L.town
      free = L.tfree
    end
    -- au-delà de 80 km/h (voies rapides), on dépasse moins la limitation en proportion
    local vTarget = min(limit, FAST_LIMIT) * over + max(0, limit - FAST_LIMIT) * (1 + (over - 1) * 0.5)
    -- vitesse que la route permet sans tenir compte de la limitation (jamais moins que la vitesse visée ;
    -- une très large route n'est pas pour autant un circuit)
    local vFree = max(22 + 5 * min(w, 12), vTarget)
    local vl = min(veh.vt * 0.98, (1 - free) * vTarget + free * vFree)
    -- trafic : on rattrape les voitures d'autant plus souvent qu'on roule vite par rapport à elles (elles
    -- roulent à la limitation) ; on perd alors du temps, sauf si on peut passer entre elles
    if traffic > 0 and vl > limit then
      vl = vl * (1 - traffic * (1 - limit / vl) * M.trafficBlock(w, smp[k].lanes, smp[k].oneWay, vehW, smp[k].town))
    end
    -- aux carrefours de ville, on croise des voitures
    if smp[k].junction then vl = min(vl, L.jn / 3.6 * (1 - 0.15 * traffic)) end
    vmax[k] = min(vc, vl)
    -- descente raide : on lève le pied, en ligne droite comme dans les virages (d'autant plus qu'on est prudent)
    local slope = smp[k].slope or 0
    if slope < -0.04 then vmax[k] = vmax[k] * (1 - L.down * (-slope - 0.04)) end
  end
  local v = {0}
  for k = 2, n do
    local u = v[k - 1]
    local slope = smp[k - 1].slope or 0
    local amax = veh.A * max(0.05, 1 - (u / veh.vt) ^ 2) -- accélération possible du véhicule à cette vitesse
    local a
    if slope > 0 then
      -- en montée, la pente prend sur la réserve du moteur : on garde son allure tant qu'il en reste
      a = min(L.accel * amax, amax - G * slope)
    else
      a = L.accel * amax - G * slope -- en descente, la pente aide
    end
    -- en virage, l'adhérence sert d'abord à tourner : on n'accélère vraiment qu'en se redressant, et plus
    -- tard encore avec une voiture qui glisse (stab)
    local sp = smp[k - 1]
    local f = sp.curv > 1e-4 and min(1.5, u * u * sp.curv / sp.latCap) or 0
    local trac = veh.aBrk * sp.gs * (veh.share or 0.6) * sqrt(max(0.05, 1 - (f / (veh.stab or 1)) ^ 2))
    a = min(a, trac - G * slope)
    local vk = sqrt(max(0, u * u + 2 * a * STEP))
    if a < 0 then
      -- côte trop raide : on ralentit jusqu'à la vitesse que le moteur peut tenir (au pire, au pas)
      local vEq = (G * slope < veh.A) and veh.vt * sqrt(1 - G * slope / veh.A) or 0
      vk = max(vk, min(max(u, V_CRAWL), max(V_CRAWL, vEq)))
    end
    v[k] = min(vmax[k], vk)
  end
  for k = n - 1, 1, -1 do
    -- en descente on freine moins bien, en montée la pente aide à ralentir ; en plein virage on ne peut pas
    -- freiner à fond (l'adhérence sert à tourner), encore moins avec une voiture qui glisse
    local sp = smp[k]
    local u = v[k + 1]
    local f = sp.curv > 1e-4 and min(1.5, u * u * sp.curv / sp.latCap) or 0
    local bTire = veh.aBrk * sp.gs * sqrt(max(0.1, 1 - (f / (veh.stab or 1)) ^ 2))
    local b = max(0.5, min(veh.aBrk * L.brake * sp.gs, bTire) + G * (sp.slope or 0))
    v[k] = min(v[k], sqrt(v[k + 1] ^ 2 + 2 * b * STEP))
  end
  v[1] = 0
  local t = 0
  for k = 1, n - 1 do
    t = t + STEP / max(0.7, (v[k] + v[k + 1]) * 0.5)
  end
  return t * L.margin, length
end

-- Secours sans trajet détaillé : vitesse moyenne typique par niveau (m/s)
local FALLBACK_SPEED = {tres_facile = 9, facile = 11, moyen = 13.5, dur = 16, tres_dur = 19, impossible = 23}
function M.fallback(dist, level)
  return (tonumber(dist) or 0) / (FALLBACK_SPEED[level] or FALLBACK_SPEED.moyen)
end

-- Bouts hors route (sortir d'un parking, rejoindre la route depuis un point à l'écart) : deux fois moins vite
function M.access(dist, level)
  dist = tonumber(dist)
  if not dist or dist ~= dist or dist <= 0 then return 0 end
  return min(dist, 2000) / ((FALLBACK_SPEED[level] or FALLBACK_SPEED.moyen) * 0.5)
end

-- Chrono jusqu'à la validation : temps des 50 derniers mètres et du stationnement (et de la validation
-- automatique, qui attend 3 s à l'arrêt)
function M.parkTime(level, autoValidation)
  local L = M.byId[level] or M.byId.moyen
  return L.park + (autoValidation and 2.5 or 0)
end

-- Niveaux où le chrono va toujours jusqu'à la validation (stationnement compris)
function M.fullChrono(level)
  local L = M.byId[level]
  return L ~= nil and L.index >= M.byId.tres_dur.index
end

return M
