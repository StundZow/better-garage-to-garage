-- Livraison Libre - temps limite selon la difficulté
-- Estime le temps qu'il faut pour faire le trajet avec un véhicule donné, à partir de ses performances
-- (0-100 km/h, vitesse max, freinage, hauteur) et du trajet (virages, limitations, terre), pour un
-- conducteur allant du débutant (très facile) au pilote (impossible). Simulation d'un profil de vitesse :
-- vitesse max autorisée par les virages et la route, puis accélération et freinage réalistes.
-- Module "pur" (nombres uniquement), testable hors du jeu.

local M = {}

local sqrt, min, max, abs, atan2, log, pi, huge = math.sqrt, math.min, math.max, math.abs, math.atan2, math.log, math.pi, math.huge
local G = 9.81
local STEP = 5          -- m : pas de la simulation
local WINDOW = 2        -- pas de part et d'autre pour mesurer la courbure (±10 m)

-- limit : facteur sur la limitation de vitesse (nil = aucune limite, seulement le véhicule)
-- grip / accel / brake : part de l'adhérence, de l'accélération et du freinage du véhicule utilisée
-- line : trajectoire (1 = reste dans sa voie ; plus = coupe les virages, rayon plus grand)
-- margin : marge sur le temps simulé
M.LEVELS = {
  {id = 'tres_facile', label = 'Très facile', limit = 0.9, grip = 0.40, accel = 0.45, brake = 0.40, line = 1.0,  margin = 1.45},
  {id = 'facile',      label = 'Facile',      limit = 1.0, grip = 0.50, accel = 0.55, brake = 0.50, line = 1.0,  margin = 1.25},
  {id = 'moyen',       label = 'Moyen',       limit = 1.2, grip = 0.65, accel = 0.75, brake = 0.65, line = 1.15, margin = 1.12},
  {id = 'dur',         label = 'Dur',         limit = 1.5, grip = 0.80, accel = 0.90, brake = 0.80, line = 1.35, margin = 1.05},
  {id = 'tres_dur',    label = 'Très dur',    limit = 1.9, grip = 0.92, accel = 1.0,  brake = 0.92, line = 1.6,  margin = 1.0},
  {id = 'impossible',  label = 'Impossible',  limit = nil, grip = 1.05, accel = 1.0,  brake = 1.0,  line = 2.0,  margin = 0.95},
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

-- Modèle du véhicule. perf = {top (m/s), z100 (s), power (kW), weight (kg), brakeG, height (m)}
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
  return {vt = vt, A = A, aBrk = bg * G, aLat = 0.9 * bg * G * heightFactor}
end

-- Rééchantillonne le trajet tous les STEP mètres (sans les trimEnd derniers mètres).
local function resample(points, trimEnd)
  local segs, total = {}, 0
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len > 0.01 then
      segs[#segs + 1] = {a = a, len = len, s0 = total, dx = dx / len, dy = dy / len, heading = atan2(dy, dx)}
      total = total + len
    end
  end
  local length = total - (trimEnd or 0)
  if #segs == 0 or length < STEP * 2 then return nil, max(0, length) end
  local samples, k, si = {}, 0, 1
  local s = 0
  while s <= length do
    while si < #segs and segs[si].s0 + segs[si].len < s do si = si + 1 end
    local sg = segs[si]
    k = k + 1
    samples[k] = {heading = sg.heading, speed = sg.a.speed, drv = sg.a.drv}
    s = s + STEP
  end
  return samples, length
end

local function wrap(a)
  while a > pi do a = a - 2 * pi end
  while a < -pi do a = a + 2 * pi end
  return a
end

-- Temps estimé (s) pour parcourir le trajet. points : graph.route() ; veh : vehicleModel() ; level : id.
-- opts.trimEnd : mètres non chronométrés à la fin (le chrono s'arrête à 50 m de la zone).
function M.estimate(points, veh, level, opts)
  opts = opts or {}
  local L = M.byId[level] or M.byId.moyen
  if type(points) ~= 'table' or #points < 2 or not veh then return nil end
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
    local grip = L.grip * (0.55 + 0.45 * drv) -- terre / route dégradée : moins d'adhérence
    smp[k].grip = grip
    local vc = curv > 1e-4 and sqrt(veh.aLat * grip * (L.line or 1) / curv) or huge
    local limit = tonumber(smp[k].speed)
    if not limit or limit <= 0 or limit > 80 then limit = 22.2 end
    local vl = L.limit and limit * L.limit or huge
    vmax[k] = min(veh.vt * 0.98, vc, vl)
  end
  local v = {0}
  for k = 2, n do
    local u = v[k - 1]
    local a = veh.A * L.accel * max(0.05, 1 - (u / veh.vt) ^ 2)
    v[k] = min(vmax[k], sqrt(u * u + 2 * a * STEP))
  end
  for k = n - 1, 1, -1 do
    local b = veh.aBrk * L.brake * (smp[k].grip / L.grip)
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

return M
