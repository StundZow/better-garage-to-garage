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
local KV_W = 3          -- pas de part et d'autre pour mesurer bosses et creux (±15 m)
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
local BLOCK = {squeeze = 0.025, lanes = 0.06, twoWay = 0.10, twoWayTown = 0.15, oneLane = 0.22}

-- limit : facteur sur la limitation de vitesse
-- wgain : effet de la largeur de la route sur ce facteur (route large : plus vite, route étroite : moins vite)
-- free : part de « je roule à la vitesse que la route permet » plutôt qu'à la limitation (0 à 1)
-- grip / accel / brake : part de l'adhérence, de l'accélération et du freinage du véhicule utilisée
-- line : trajectoire : line - 1 = part de la place libre de la route utilisée pour couper les virages
-- (0 : reste au milieu ; 1 : toute la largeur)
-- En ville (carrefours rapprochés) : town = part du dépassement de la limitation gardée, tfree = part de
-- « vitesse que la route permet », jn = vitesse de passage d'un carrefour (km/h).
-- down : prudence en descente raide (on lève le pied au-delà de 4 % de pente).
-- park : temps pour les 50 derniers mètres et le stationnement, quand le chrono va jusqu'à la validation.
-- margin : marge sur le temps simulé
M.LEVELS = {
  {id = 'tres_facile', label = 'Très facile',    limit = 0.9, wgain = 0.06, free = 0,    grip = 0.40, accel = 0.45, brake = 0.40, line = 1.05,
   town = 1,    tfree = 0,    jn = 26, down = 2.0, park = 36, margin = 1.39},
  {id = 'facile',      label = 'Facile',         limit = 1.0, wgain = 0.08, free = 0,    grip = 0.50, accel = 0.55, brake = 0.50, line = 1.08,
   town = 1,    tfree = 0,    jn = 32, down = 1.6, park = 28, margin = 1.17},
  {id = 'moyen',       label = 'Moyen',          limit = 1.2, wgain = 0.17, free = 0.05, grip = 0.65, accel = 0.75, brake = 0.65, line = 1.15,
   town = 0.7,  tfree = 0,    jn = 42, down = 1.2, park = 22, margin = 1.04},
  {id = 'dur',         label = 'Difficile',      limit = 1.5, wgain = 0.33, free = 0.15, grip = 0.80, accel = 0.90, brake = 0.80, line = 1.35,
   town = 0.65, tfree = 0,    jn = 55, down = 0.8, park = 18, margin = 0.94},
  {id = 'tres_dur',    label = 'Très difficile', limit = 1.9, wgain = 0.47, free = 0.35, grip = 0.92, accel = 1.0,  brake = 0.92, line = 1.6,
   town = 0.65, tfree = 0.1,  jn = 65, down = 0.5, park = 14, margin = 0.89},
  {id = 'impossible',  label = 'Impossible',     limit = 2.0, wgain = 0.5,  free = 1,    grip = 1.05, accel = 1.0,  brake = 1.0,  line = 2.0,
   town = 0.55, tfree = 0.3,  jn = 78, down = 0.2, park = 10, margin = 0.815},
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
  local wheels, driven = drive:match('(%d+)X(%d+)') -- '4x4', '6x6', '8x8' : toutes les roues motrices
  if drive:find('AWD', 1, true) or drive:find('4WD', 1, true) or (wheels and wheels == driven) then
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

local function wrap(a)
  while a > pi do a = a - 2 * pi end
  while a < -pi do a = a + 2 * pi end
  return a
end

-- Géométrie « courbe par courbe ». Dans le réseau routier du jeu, un virage est une ligne brisée (un point
-- tous les 13-15 m, 14-15° par point). À chaque coude, on pose l'arc de cercle tangent aux deux segments
-- (au plus jusqu'à leur milieu) : rayon = longueur de tangence / tan(angle / 2). Les arcs qui tournent dans
-- le même sens forment une courbe (angle total : ce qu'un pilote peut couper) ; une vraie courbe en sens
-- inverse juste avant ou après, presque aussi serrée, forme un S (on ne coupe pas les deux à fond). Les
-- petits coudes de quelques degrés du tracé ne comptent pas, et devant une courbe bien plus douce on
-- sacrifie la douce.
local CORNER_T_MAX = 15 -- m : au plus 15 m de part et d'autre d'un coude franc (carrefour, angle droit)
local CURVE_GAP = 5     -- m : arcs du même sens qui se touchent = une courbe
local TURN_GAP = 25     -- m : deux vrais virages (15° et plus) du même sens plus proches = un seul virage
local S_GAP = 25        -- m : courbe en sens inverse à moins de 25 m = virage en S...
local S_MIN = 0.26      -- rad : ... si elle tourne d'au moins 15°
local R_MIN = 5         -- m : aucun virage plus serré que le braquage d'une voiture
local function curvesOf(pts, cum)
  local arcs = {}
  for i = 2, #pts - 1 do
    local a, b, c = pts[i - 1], pts[i], pts[i + 1]
    local l1 = sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    local l2 = sqrt((c.x - b.x) ^ 2 + (c.y - b.y) ^ 2)
    if l1 > 0.05 and l2 > 0.05 then
      local th = wrap(atan2(c.y - b.y, c.x - b.x) - atan2(b.y - a.y, b.x - a.x))
      local ath = min(abs(th), 3.0) -- demi-tour complet : au plus ~172°
      if ath > 0.003 then
        local t = min(l1, l2) * 0.5
        if ath > 0.52 then t = min(t, CORNER_T_MAX) end -- coude franc (plus de 30°)
        local sign, h1, R = th > 0 and 1 or -1, atan2(b.y - a.y, b.x - a.x), t / math.tan(ath * 0.5)
        local x1, y1 = b.x - math.cos(h1) * t, b.y - math.sin(h1) * t -- début de l'arc
        arcs[#arcs + 1] = {s0 = cum[i] - t, s1 = cum[i] + t, curv = min(1 / R_MIN, 1 / R), sign = sign, th = ath, i = i,
          R = R, h1 = h1, cx = x1 - sign * R * math.sin(h1), cy = y1 + sign * R * math.cos(h1)}
      end
    end
  end
  local curves = {}
  for j, arc in ipairs(arcs) do
    local prev = arcs[j - 1]
    if prev and prev.sign == arc.sign and arc.s0 - prev.s1 <= CURVE_GAP then
      local cv = curves[#curves]
      cv.theta, cv.s1, cv.kmax, cv.a1 = cv.theta + arc.th, arc.s1, max(cv.kmax, arc.curv), j
    else
      curves[#curves + 1] = {theta = arc.th, s0 = arc.s0, s1 = arc.s1, sign = arc.sign, kmax = arc.curv, a0 = j, a1 = j}
    end
  end
  -- deux vrais virages du même sens séparés d'un petit bout droit : un seul virage (on le prend d'un seul
  -- tenant) ; les petits coudes du tracé ne s'y ajoutent pas
  local turns = {}
  for _, cv in ipairs(curves) do
    local last = turns[#turns]
    if last and last.sign == cv.sign and cv.s0 - last.s1 <= TURN_GAP and last.theta >= S_MIN and cv.theta >= S_MIN then
      last.theta, last.s1, last.kmax, last.a1 = last.theta + cv.theta, cv.s1, max(last.kmax, cv.kmax), cv.a1
    else
      turns[#turns + 1] = cv
    end
  end
  curves = turns
  for ci, cv in ipairs(curves) do
    for j = cv.a0, cv.a1 do arcs[j].curve = ci end
  end
  -- virage en S : la plus proche vraie courbe (avant, puis après) à moins de S_GAP tourne dans l'autre sens
  -- et elle est assez serrée pour qu'on ne puisse pas la prendre par l'intérieur à la vitesse de celle-ci
  -- (rayon de moins de 2 fois le sien + 3 m)
  for j, cv in ipairs(curves) do
    cv.sbend = false
    for dir = -1, 1, 2 do
      local i = j + dir
      while curves[i] and not cv.sbend do
        local o = curves[i]
        if (dir < 0 and cv.s0 - o.s1 or o.s0 - cv.s1) > S_GAP then break end
        if o.theta >= S_MIN then
          cv.sbend = o.sign ~= cv.sign and 1 / o.kmax < 2 / cv.kmax + 3
          break
        end
        i = i + dir
      end
    end
  end
  return arcs, curves
end

-- Trajectoire idéale, courbe par courbe. Le milieu de la route est remplacé par son cercle équivalent :
-- tangent à la route d'entrée et à la route de sortie, et passant au point du milieu de la route le plus
-- proche du coin (ce qui lisse les coudes du tracé du GPS). La trajectoire est le plus grand cercle qui entre
-- par l'extérieur, touche la corde à l'intérieur et ressort par l'extérieur de la place libre (2 h) :
-- rayon R - h + 2 h / (1 - cos(angle / 2)). Dans un demi-tour (166 à 195°), le cercle équivalent a pour
-- diamètre l'écart entre la route d'entrée et celle de sortie (presque parallèles) ; dans une boucle (plus
-- de 195°), le rayon moyen du virage (longueur / angle) ; la trajectoire fait R + h.
local HAIRPIN = 2.9 -- rad (166°) : au-delà, demi-tour
local function arcPoint(arc, f)
  local hd = arc.h1 + arc.sign * arc.th * f
  return arc.cx + arc.sign * arc.R * math.sin(hd), arc.cy - arc.sign * arc.R * math.cos(hd)
end
-- routes d'entrée et de sortie d'un virage : le segment du tracé juste avant (après) ; s'il fait moins de
-- SHORT_SEG et qu'il mène à un petit coude (moins de 15°), le segment d'avant (d'après) : le tracé du GPS fait
-- souvent un petit crochet juste avant ou après un carrefour
local SHORT_SEG = 8 -- m
local function cornersOf(pts, arcs, curves)
  local turn = {}
  for _, arc in ipairs(arcs) do turn[arc.i] = arc.th end
  local function dist(a, b) return sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) end
  for _, cv in ipairs(curves) do
    local i0, i1 = arcs[cv.a0].i, arcs[cv.a1].i
    local p0, p1, q0, q1 = pts[i0 - 1], pts[i0], pts[i1], pts[i1 + 1]
    if dist(p0, p1) < SHORT_SEG and pts[i0 - 2] and (turn[i0 - 1] or 0) < S_MIN and dist(pts[i0 - 2], p0) > 1 then
      p0, p1 = pts[i0 - 2], pts[i0 - 1]
    end
    if dist(q0, q1) < SHORT_SEG and pts[i1 + 2] and (turn[i1 + 1] or 0) < S_MIN and dist(q1, pts[i1 + 2]) > 1 then
      q0, q1 = pts[i1 + 1], pts[i1 + 2]
    end
    local px, py, qx, qy = p1.x, p1.y, q0.x, q0.y
    local ax, ay, bx, by = p1.x - p0.x, p1.y - p0.y, q1.x - q0.x, q1.y - q0.y
    local la, lb = sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by)
    ax, ay, bx, by = ax / la, ay / la, bx / lb, by / lb
    local cr = ax * by - ay * bx
    cv.Req, cv.sApex, cv.th = 1 / cv.kmax, (cv.s0 + cv.s1) * 0.5, min(cv.theta, pi)
    if cv.theta < HAIRPIN and cr * cv.sign > 1e-3 then
      -- coin : intersection des routes d'entrée et de sortie
      local t = ((qx - px) * by - (qy - py) * bx) / cr
      local vx, vy = px + ax * t, py + ay * t
      -- point du milieu de la route le plus proche du coin (sur les arcs et les bouts droits entre eux)
      local dmin, sAt = huge, cv.sApex
      for j = cv.a0, cv.a1 do
        local arc = arcs[j]
        for f = 0, 1, 0.125 do
          local x, y = arcPoint(arc, f)
          local d = sqrt((x - vx) ^ 2 + (y - vy) ^ 2)
          if d < dmin then dmin, sAt = d, arc.s0 + (arc.s1 - arc.s0) * f end
        end
        local nx = arcs[j + 1]
        if j < cv.a1 and nx.s0 > arc.s1 then
          local ex, ey = arcPoint(arc, 1)
          local fx, fy = arcPoint(nx, 0)
          local sx, sy = fx - ex, fy - ey
          local u = clamp(((vx - ex) * sx + (vy - ey) * sy) / max(1e-9, sx * sx + sy * sy), 0, 1)
          local d = sqrt((ex + sx * u - vx) ^ 2 + (ey + sy * u - vy) ^ 2)
          if d < dmin then dmin, sAt = d, arc.s1 + (nx.s0 - arc.s1) * u end
        end
      end
      local th = math.acos(clamp(ax * bx + ay * by, -1, 1))
      local c = math.cos(th * 0.5)
      cv.Req = max(cv.Req, dmin * c / max(1e-9, 1 - c))
      cv.th, cv.c, cv.sApex, cv.vx, cv.vy, cv.ax, cv.ay, cv.bx, cv.by = th, c, sAt, vx, vy, ax, ay, bx, by
    else
      -- demi-tour, boucle (jamais plus serré que l'arc le plus serré) ; sommet : là où la moitié du virage
      -- est faite
      cv.hair = true
      local acc = 0
      for j = cv.a0, cv.a1 do
        acc = acc + arcs[j].th
        if acc >= cv.theta * 0.5 then cv.sApex = (arcs[j].s0 + arcs[j].s1) * 0.5 break end
      end
      if cv.theta >= HAIRPIN and cv.theta <= 3.4 then
        cv.Req = max(cv.Req, abs((qx - px) * ay - (qy - py) * ax) * 0.5)
      else
        cv.Req = max(cv.Req, (cv.s1 - cv.s0) / cv.theta)
      end
    end
    -- largeur de la route la plus étroite dans la courbe
    local w = huge
    for i = i0, i1 do w = min(w, pts[i].r and pts[i].r * 2 or ROAD_WIDTH) end
    cv.w = w
  end
end

-- Rééchantillonne le trajet tous les STEP mètres (sans les trimEnd derniers mètres).
-- Chaque point : courbure du milieu de la route, limitation, état, largeur, voies, altitude et pente, et s'il
-- est en ville / dans un carrefour de ville. Renvoie aussi les courbes (trajectoire idéale de chacune).
local function resample(points, trimEnd)
  local segs, total = {}, 0
  local clean, cum = {points[1]}, {0}
  for i = 1, #points - 1 do
    local a, b = points[i], points[i + 1]
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len > 0.01 then
      segs[#segs + 1] = {a = a, len = len, s0 = total, dx = dx, dy = dy, dz = dz, heading = atan2(dy, dx),
        slope = clamp(dz / len, -MAX_SLOPE, MAX_SLOPE)}
      total = total + len
      clean[#clean + 1] = b
      cum[#cum + 1] = total
    end
  end
  local length = total - (trimEnd or 0)
  if #segs == 0 or length < STEP * 2 then return nil, max(0, length) end
  local town = junctions(points)
  local arcs, curves = curvesOf(clean, cum)
  cornersOf(clean, arcs, curves)
  local samples, k, si, ji, ai = {}, 0, 1, 1, 1
  local s = 0
  while s <= length do
    while si < #segs and segs[si].s0 + segs[si].len < s do si = si + 1 end
    local sg = segs[si]
    k = k + 1
    -- carrefour de ville le plus proche (liste triée : on avance au fur et à mesure)
    while town[ji + 1] and abs(town[ji + 1] - s) <= abs(town[ji] - s) do ji = ji + 1 end
    local dj = town[ji] and abs(town[ji] - s) or huge
    -- arc où se trouve ce point
    while arcs[ai] and arcs[ai].s1 < s do ai = ai + 1 end
    local arc = arcs[ai]
    local inArc = arc and arc.s0 <= s
    samples[k] = {heading = sg.heading, speed = sg.a.speed, drv = sg.a.drv, width = sg.a.r and sg.a.r * 2 or nil, slope = sg.slope,
      x = sg.a.x + sg.dx * clamp((s - sg.s0) / sg.len, 0, 1), y = sg.a.y + sg.dy * clamp((s - sg.s0) / sg.len, 0, 1),
      z = sg.a.z + sg.dz * clamp((s - sg.s0) / sg.len, 0, 1), curv = inArc and arc.curv or 0, ci = inArc and arc.curve or nil,
      lanes = sg.a.lanes, oneWay = sg.a.oneWay, town = dj <= TOWN_R, junction = dj <= JUNCTION_R}
    s = s + STEP
  end
  return samples, length, curves
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

local simulate -- (défini plus bas)

-- Temps estimé (s) pour parcourir le trajet. points : graph.route() ; veh : vehicleModel() ; level : id.
-- Un meilleur conducteur peut toujours rouler comme un moins bon : le temps d'un niveau n'est jamais plus long
-- que celui des niveaux en dessous sur le même trajet (avant la marge propre à chaque niveau).
function M.estimate(points, veh, level, opts)
  local L = M.byId[level] or M.byId.moyen
  local best, length = simulate(points, veh, L, opts, opts and opts.profile)
  if not best then return nil end
  for i = 1, L.index - 1 do
    local t = simulate(points, veh, M.LEVELS[i], opts)
    if t and t < best then best = t end
  end
  return best * L.margin, length
end

-- Simulation pour un niveau : temps sans la marge du niveau.
-- opts.trimEnd : mètres non chronométrés à la fin (le chrono s'arrête à 50 m de la zone).
-- opts.traffic : densité du trafic (M.trafficDensity) : on suit les autres, on croise aux carrefours.
-- opts.vehW : largeur du véhicule (m), pour savoir s'il passe entre les voitures du trafic.
simulate = function(points, veh, L, opts, profile)
  opts = opts or {}
  if type(points) ~= 'table' or #points < 2 or not veh then return nil end
  local traffic = clamp(tonumber(opts.traffic) or 0, 0, 1.5)
  local vehW = clamp(tonumber(opts.vehW) or 1.9, 1, 4)
  local smp, length, curves = resample(points, opts.trimEnd or 50)
  if not smp then
    -- trajet très court : départ arrêté, accélération seulement
    return max(5, sqrt(2 * max(length, 1) / max(0.5, veh.A * L.accel))), length
  end
  local n = #smp
  -- trajectoire idéale de chaque courbe pour ce niveau (part de la place libre utilisée ; virage en S : on ne
  -- coupe pas les deux à fond) : un cercle, sur toute sa longueur (centrée sur le point le plus proche du coin).
  -- Les points d'une courbe couverts par sa trajectoire prennent la courbure de celle-ci ; les autres gardent
  -- celle du milieu de la route (ou d'une trajectoire voisine plus serrée).
  local frac, lineK, own = clamp((L.line or 1) - 1, 0, 1), {}, {}
  for ci, cv in ipairs(curves) do
    if cv.theta >= 0.05 then
      local h = max(0, (clamp(cv.w, 2.5, 30) - vehW - 0.6) * 0.5) * frac
      if cv.sbend then h = h * 0.5 end
      local R = cv.hair and (cv.Req + h) or (cv.Req - h + 2 * h / max(1e-6, 1 - cv.c))
      cv.h, cv.Rl = h, R
      local half = min(R * max(cv.th, cv.theta) * 0.5, (cv.s1 - cv.s0) * 0.5 + 150) -- boucle : angle entier
      for k = max(1, math.floor((cv.sApex - half) / STEP) + 1), min(n, math.ceil((cv.sApex + half) / STEP) + 1) do
        lineK[k] = max(lineK[k] or 0, 1 / R)
        if smp[k].ci == ci then own[k] = true end
      end
    end
  end
  -- bosses et creux : courbure verticale du profil (négative sur une bosse), sur ±15 m
  for k = 1, n do
    local a, b = k - KV_W, k + KV_W
    local kv = 0
    if a >= 1 and b <= n then
      local d = KV_W * STEP
      kv = (smp[b].z - 2 * smp[k].z + smp[a].z) / (d * d)
      if abs(kv) < 0.002 then kv = 0 end -- moins marqué qu'un rayon de 500 m : rien
    end
    smp[k].kv = clamp(kv, -0.03, 0.03)
  end
  local vmax = {}
  for k = 1, n do
    local curv = own[k] and lineK[k] or max(lineK[k] or 0, smp[k].curv or 0)
    smp[k].curv = curv
    local drv = clamp(tonumber(smp[k].drv) or 1, 0, 1)
    local dirt = veh.dirt or 0.55
    local gs = dirt + (1 - dirt) * drv -- terre / route dégradée : moins d'adhérence (moins avec des pneus tout-terrain)
    local grip = L.grip * gs
    smp[k].grip, smp[k].gs = grip, gs
    -- une route large permet de rouler plus vite qu'une petite route étroite
    local w = clamp(tonumber(smp[k].width) or ROAD_WIDTH, 2.5, 30)
    -- vitesse dans le virage, sur la trajectoire ; sur une bosse la voiture s'allège (moins d'adhérence), dans
    -- un creux elle est plaquée au sol (un peu plus) ; et sur une bosse marquée, on ne va pas jusqu'à décoller
    local kv = smp[k].kv or 0
    local a0 = veh.aLat * grip
    local vc = huge
    if curv > 1e-4 then
      if kv < 0 then
        vc = sqrt(a0 / (curv - a0 * kv / G))
      else
        vc = sqrt(a0 / curv * min(1.2, 1 / max(0.5, 1 - a0 / curv * kv / G)))
      end
    end
    if kv < 0 then vc = min(vc, sqrt(0.85 * G / -kv)) end
    -- pour le cercle d'adhérence : adhérence latérale totale du véhicule ici
    smp[k].latCap = veh.aLat * gs
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
    local load = clamp(1 + u * u * (sp.kv or 0) / G, 0.3, 1.2) -- bosse : roues délestées ; creux : plaquées
    local trac = max(veh.aBrk * (veh.share or 0.6), veh.A) * sp.gs * load * sqrt(max(0.05, 1 - (f / (veh.stab or 1)) ^ 2))
    a = min(a, trac - G * slope)
    local vk = sqrt(max(0, u * u + 2 * a * STEP))
    if slope > 0 then
      -- côte : on ralentit jusqu'à la vitesse que le moteur peut tenir, mais jamais sous le pas (en
      -- première), même s'il reste un peu de réserve ; sans aller plus vite qu'à plat
      local vEq = (G * slope < veh.A) and veh.vt * sqrt(1 - G * slope / veh.A) or 0
      local vFlat = sqrt(u * u + 2 * min(L.accel * amax, trac) * STEP)
      vk = max(vk, min(max(u, V_CRAWL), max(V_CRAWL, vEq), vFlat))
    end
    v[k] = min(vmax[k], vk)
  end
  for k = n - 1, 1, -1 do
    -- en descente on freine moins bien, en montée la pente aide à ralentir ; en plein virage on ne peut pas
    -- freiner à fond (l'adhérence sert à tourner), encore moins avec une voiture qui glisse
    local sp = smp[k]
    local u = v[k + 1]
    local f = sp.curv > 1e-4 and min(1.5, u * u * sp.curv / sp.latCap) or 0
    local load = clamp(1 + u * u * (sp.kv or 0) / G, 0.3, 1.2)
    local bTire = veh.aBrk * sp.gs * load * sqrt(max(0.1, 1 - (f / (veh.stab or 1)) ^ 2))
    local b = max(0.5, min(veh.aBrk * L.brake * sp.gs * load, bTire) + G * (sp.slope or 0))
    v[k] = min(v[k], sqrt(v[k + 1] ^ 2 + 2 * b * STEP))
  end
  v[1] = 0
  local t = 0
  for k = 1, n - 1 do
    t = t + STEP / max(0.7, (v[k] + v[k + 1]) * 0.5)
  end
  -- profil détaillé (schémas, diagnostic) : position, courbure de la trajectoire, vitesse permise et vitesse
  -- simulée tous les 5 m ; et la trajectoire de chaque courbe (coin, cercle équivalent, cercle de la trajectoire)
  if type(profile) == 'table' then
    for k = 1, n do
      profile[k] = {s = (k - 1) * STEP, x = smp[k].x, y = smp[k].y, z = smp[k].z, v = v[k], vmax = vmax[k],
        curv = smp[k].curv, width = smp[k].width, town = smp[k].town, junction = smp[k].junction}
    end
    profile.curves = {}
    for i, cv in ipairs(curves) do
      profile.curves[i] = {s0 = cv.s0, s1 = cv.s1, sApex = cv.sApex, theta = cv.th, side = cv.sign, sbend = cv.sbend,
        hairpin = cv.hair or false, Req = cv.Req, R = cv.Rl, h = cv.h, w = cv.w, vx = cv.vx, vy = cv.vy,
        ax = cv.ax, ay = cv.ay, bx = cv.bx, by = cv.by}
    end
  end
  return t, length
end

-- Secours sans trajet détaillé : vitesse moyenne typique par niveau (m/s)
local FALLBACK_SPEED = {tres_facile = 9.8, facile = 12.2, moyen = 15.3, dur = 18.8, tres_dur = 21.8, impossible = 26}
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
