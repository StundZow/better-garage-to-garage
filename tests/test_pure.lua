local graph = require('/lua/ge/extensions/livraisonLibre/graph')
local loc = require('/lua/ge/extensions/livraisonLibre/locations')
local citygen = require('citygen')

local passed, failed = 0, 0
local function check(cond, name, extra)
  if cond then passed = passed + 1 else failed = failed + 1; print('  FAIL: ' .. name .. (extra and (' -> ' .. tostring(extra)) or '')) end
end
local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- RNG déterministe (même générateur que le jeu)
math.randomseed(12345)
local rng = math.random

local N, SP = 8, 120
local nodes, drives = citygen.city(N, SP)
local g = graph.build(nodes)

print('-- graph')
check(g.n == N * N + drives + 2, 'node count', g.n)
local expectedEdges = 2 * N * (N - 1) + drives + 1
check(g.ne == expectedEdges, 'edge count', g.ne .. ' vs ' .. expectedEdges)
check(g.compCount == 2, 'components = 2 (ville + île)', g.compCount)
check(g.comp[g.idx['g0_0']] == g.mainComp, 'main comp is the city')
check(g.comp[g.idx['isl1']] ~= g.mainComp, 'island separate')
check(g.deg[g.idx['g0_0']] == 2, 'corner degree 2', g.deg[g.idx['g0_0']])
check(g.deg[g.idx['g3_3']] == 4, 'center degree 4', g.deg[g.idx['g3_3']])

print('-- dijkstra')
local dist = graph.dijkstra(g, {{node = g.idx['g0_0'], d = 0}})
local far = dist[g.idx['g' .. (N - 1) .. '_' .. (N - 1)]]
check(approx(far, 2 * (N - 1) * SP, 1e-3), 'manhattan distance corner->corner', far)
check(dist[g.idx['isl1']] == nil, 'island unreachable')
local bounded = graph.dijkstra(g, {{node = g.idx['g0_0'], d = 0}}, 250)
local cnt = 0
for _, d in pairs(bounded) do cnt = cnt + 1; check(d <= 250, 'bounded dist <= max', d) end
check(cnt > 3 and cnt < 15, 'bounded dijkstra node count', cnt)

print('-- nearestEdge')
local ei, t, d = graph.nearestEdge(g, 60, 3, 10, 50)
check(ei ~= nil, 'nearest edge found')
if ei then
  local e = g.edges[ei]
  local ids = g.ids[e.a] .. '-' .. g.ids[e.b]
  check(ids == 'g0_0-g1_0' or ids == 'g1_0-g0_0', 'nearest edge is g0_0-g1_0', ids)
  check(approx(t, 0.5, 0.01), 'param t = 0.5', t)
  check(approx(d, 3, 1e-6), 'distance 3', d)
end
check(graph.nearestEdge(g, 60, 3, 100, 50, nil, 6) == nil, 'z filter rejects bridge level')
local srcs = graph.sourcesFor(g, ei, t, d)
local dd = graph.dijkstra(g, srcs)
local p0 = {e = ei, t = t, off = d, x = 60, y = 3, z = 10}
local pd = loc.candDist(g, dd, {e = ei, t = t, off = d}, p0)
check(approx(pd, 2 * d, 1e-6), 'same point distance = access offsets only', pd)
local pd2 = loc.candDist(g, dd, {e = ei, t = t + 0.25, off = 0}, p0)
check(approx(pd2, 0.25 * 120 + d, 1e-6), 'same edge distance is direct', pd2)

print('-- road spots / dead ends')
local road = loc.buildRoadSpots(g)
local homes = loc.buildDeadEnds(g)
check(#road > 50, 'road spots generated', #road)
check(#homes == drives, 'dead ends = driveways', #homes .. ' vs ' .. drives)
local anyHighway, anyDirt, anyOneWay = false, false, false
for _, c in ipairs(road) do
  local e = g.edges[c.e]
  check(not e.private, 'no road spot on private road')
  local da, db = c.t * e.len, (1 - c.t) * e.len
  if g.deg[e.a] >= 3 then check(da >= 18 - 1e-6, 'junction margin a', da) end
  if g.deg[e.b] >= 3 then check(db >= 18 - 1e-6, 'junction margin b', db) end
  anyHighway = anyHighway or c.highway
  anyDirt = anyDirt or c.drv < 0.7
  anyOneWay = anyOneWay or c.oneWay
end
check(anyHighway and anyDirt and anyOneWay, 'variety of road spots (highway, dirt, one-way)')

print('-- zone placement')
local c0
for _, c in ipairs(road) do if not c.oneWay and not c.highway and c.drv >= 1 then c0 = c break end end
local z1 = loc.zoneFor(c0, 2.0, 4.8, 1.3, 1, 1)
check(z1 ~= nil, 'zone computed')
check(approx(z1.w, 2.6) and approx(z1.l, 6.24), 'zone is 1.3x the vehicle', z1.w .. 'x' .. z1.l)
-- décalage latéral : le bord de la zone doit coller au bord de la route (marge 0.15)
local side = (z1.x - c0.x) * z1.rx + (z1.y - c0.y) * z1.ry
check(approx(side, c0.half - z1.w / 2 - 0.15, 1e-6), 'lateral offset right side', side)
local z2 = loc.zoneFor(c0, 2.0, 4.8, 1.3, -1, 1)
local side2 = (z2.x - c0.x) * z2.rx + (z2.y - c0.y) * z2.ry
check(approx(side2, -(c0.half - z2.w / 2 - 0.15), 1e-6), 'lateral offset left-hand traffic', side2)
local z3 = loc.zoneFor(c0, 2.0, 4.8, 1.3, 1, -1)
check(approx(z3.fx, -z1.fx) and approx(z3.fy, -z1.fy), 'dirSign flips direction')
check(loc.pointInZone(z1, z1.x, z1.y, z1.z), 'center in zone')
check(not loc.pointInZone(z1, z1.x + z1.rx * 2, z1.y + z1.ry * 2, z1.z), 'point 2m sideways out of zone')
check(loc.pointInZone(z1, z1.x + z1.fx * 3, z1.y + z1.fy * 3, z1.z), 'point 3m ahead inside (half length 3.12)')
-- un camion ne rentre pas sur une route trop étroite
local narrow = {kind = 'road', half = 1.5, x = 0, y = 0, z = 0, fx = 0, fy = 1, fz = 0, ux = 0, uy = 0, uz = 1}
check(loc.zoneFor(narrow, 2.5, 9, 1.3, 1, 1) == nil, 'truck rejected on narrow road')
check(loc.zoneFor(narrow, 2.5, 9, 1.3, 1, 1, true) ~= nil, 'force=true still computes zone')
-- sens unique : la direction suit inNode -> outNode
for _, c in ipairs(road) do
  if c.oneWay then
    local e = g.edges[c.e]
    local zin = loc.zoneFor(c, 2, 4.8, 1.3, 1, -1)
    local inN = e.inNode
    local outN = (inN == e.a) and e.b or e.a
    local dx, dy = g.x[outN] - g.x[inN], g.y[outN] - g.y[inN]
    check(zin.fx * dx + zin.fy * dy > 0, 'one-way direction follows traffic')
    break
  end
end

print('-- parking spots')
local spots = {
  {name = 'p1', kind = 'parking', label = 'Parking', x = 125, y = 60, z = 10, fx = 1, fy = 0, fz = 0, w = 2.5, l = 6},
  {name = 'p1dup', kind = 'parking', x = 125.3, y = 60.2, z = 10, fx = 1, fy = 0, fz = 0, w = 2.5, l = 6},
  {name = 'gas', kind = 'poi', label = 'levels.test.gasStationPoints.apex.title', x = 370, y = 250, z = 10, fx = 0, fy = 1, fz = 0, w = 3, l = 7},
  {name = 'far', kind = 'parking', x = 2000, y = 2000, z = 10, fx = 0, fy = 1, fz = 0, w = 2.5, l = 6},
}
local att = loc.attachSpots(g, spots)
check(#att == 2, 'spots attached (dedup + far rejected)', #att)
check(att[1] and att[1].off > 0 and att[1].off < 10, 'attach offset', att[1] and att[1].off)
check(loc.fits(att[1], 2.0, 4.8, 1.3), 'car fits in spot')
check(not loc.fits(att[1], 2.5, 9.0, 1.3), 'truck does not fit in spot')

print('-- pickMission (random)')
local cands = {}
for _, l in ipairs({road, homes, att}) do for _, c in ipairs(l) do cands[#cands + 1] = c end end
local base = {
  g = g, cands = cands, minD = 300, maxD = 700, vehW = 2.0, vehL = 4.8, scale = 1.3, legalSide = 1, rng = rng,
  filter = {kinds = {road = true, parking = true, poi = true, home = true}, paved = true, pavedThreshold = 0.7, avoidHighways = true},
}
local kindsSeen = {}
local okRuns, relaxedRuns = 0, 0
for run = 1, 200 do
  local ctx = {}
  for k, v in pairs(base) do ctx[k] = v end
  local res, why = loc.pickMission(ctx)
  if res then
    okRuns = okRuns + 1
    if res.relaxed then relaxedRuns = relaxedRuns + 1 end
    if not res.relaxed then
      check(res.dist >= 300 and res.dist <= 700, 'distance within range', res.dist)
    end
    kindsSeen[res.dest.kind] = (kindsSeen[res.dest.kind] or 0) + 1
    check(res.dest.drv >= 0.7, 'paved destination only', res.dest.drv)
    check(not res.dest.highway, 'no highway destination')
    check(res.pickup ~= res.dest, 'pickup ~= dest')
    check(res.pickup.comp == g.mainComp, 'pickup in main component')
    -- vérification indépendante de la distance routière (dans le sens de circulation, comme le GPS)
    local dchk = graph.dijkstra(g, graph.sourcesFor(g, res.pickup.e, res.pickup.t, res.pickup.off, 1), nil, nil, 1)
    local real = loc.candDist(g, dchk, res.dest, res.pickup, 1)
    check(real and approx(real, res.dist, 1e-6), 'reported dist matches dijkstra', tostring(real) .. ' vs ' .. res.dist)
    local rpts = graph.route(g, res.pickup, res.dest)
    local rlen = 0
    for k = 1, rpts and #rpts - 1 or 0 do rlen = rlen + math.sqrt((rpts[k + 1].x - rpts[k].x) ^ 2 + (rpts[k + 1].y - rpts[k].y) ^ 2 + (rpts[k + 1].z - rpts[k].z) ^ 2) end
    check(rpts and math.abs(rlen + (res.pickup.off or 0) + (res.dest.off or 0) - res.dist) < 0.01, 'distance annoncée = longueur du trajet (temps limite)', rlen .. ' vs ' .. res.dist)
  else
    print('  no result:', why)
  end
end
check(okRuns == 200, 'all runs produce a mission', okRuns)
print(string.format('  runs ok=%d relaxed=%d kinds: road=%d parking=%d poi=%d home=%d', okRuns, relaxedRuns,
  kindsSeen.road or 0, kindsSeen.parking or 0, kindsSeen.poi or 0, kindsSeen.home or 0))
check((kindsSeen.home or 0) > 10 and (kindsSeen.road or 0) > 10, 'destinations spread across kinds')

-- surface "toutes routes" : des destinations en terre deviennent possibles
local dirtSeen = 0
for run = 1, 150 do
  local ctx = {}
  for k, v in pairs(base) do ctx[k] = v end
  ctx.filter = {kinds = {road = true}, paved = false, avoidHighways = false}
  ctx.minD, ctx.maxD = 100, 3000
  local res = loc.pickMission(ctx)
  if res and res.dest.drv < 0.7 then dirtSeen = dirtSeen + 1 end
end
check(dirtSeen > 5, 'dirt destinations allowed with surface=any', dirtSeen)

print('-- orientation du véhicule au départ vers le GPS')
local okRoad, nRoad, okSpot, nSpot, okHome, nHome = 0, 0, 0, 0, 0, 0
for run = 1, 300 do
  local ctx = {}
  for k, v in pairs(base) do ctx[k] = v end
  local res = loc.pickMission(ctx)
  if res and res.pickup.e then
    local p = res.pickup
    local e = g.edges[p.e]
    -- trajet restant (légal, à rebours depuis la destination) en partant vers a / vers b
    local fromDest = graph.dijkstra(g, graph.sourcesFor(g, res.dest.e, res.dest.t, res.dest.off, -1), nil, nil, -1)
    local viaA, viaB = graph.endDists(g, fromDest, p.e, p.t, -1)
    viaA, viaB = viaA or math.huge, viaB or math.huge
    local dx, dy = g.x[e.b] - g.x[e.a], g.y[e.b] - g.y[e.a]
    local z = res.pickupZone
    if p.kind == 'road' and not p.oneWay then
      nRoad = nRoad + 1
      local facesB = (z.fx * dx + z.fy * dy) > 0
      -- le sens choisi mène au plus court (égalité : l'un ou l'autre)
      if (facesB and viaB <= viaA + 1e-6) or (not facesB and viaA <= viaB + 1e-6) then okRoad = okRoad + 1 end
      -- toujours garé du bon côté (à droite du sens de marche)
      local side = (z.x - p.x) * z.rx + (z.y - p.y) * z.ry
      check(side >= -1e-6, 'départ garé à droite dans son sens de marche', side)
    elseif p.kind ~= 'road' then
      nSpot = nSpot + 1
      local l = math.sqrt(dx * dx + dy * dy)
      local ok = false
      for _, sgn in ipairs({1, -1}) do
        if (sgn == 1 and viaB <= viaA + 1e-6) or (sgn == -1 and viaA <= viaB + 1e-6) then
          local px = g.x[e.a] + dx * p.t + sgn * dx / l * 15
          local py = g.y[e.a] + dy * p.t + sgn * dy / l * 15
          if z.fx * (px - z.x) + z.fy * (py - z.y) >= 0 then ok = true end
        end
      end
      if ok then okSpot = okSpot + 1 end
      if p.deadEnd then
        -- fond d'allée : on repart toujours vers la rue, jamais le nez dans l'allée
        nHome = nHome + 1
        if z.fx * p.fx + z.fy * p.fy < 0 then okHome = okHome + 1 end
      end
    end
  end
end
print(string.format('  route: %d/%d orientés vers le GPS, places/allées: %d/%d (allées vers la rue %d/%d)', okRoad, nRoad, okSpot, nSpot, okHome, nHome))
check(nRoad > 20 and okRoad == nRoad, 'départ sur route orienté vers la destination', okRoad .. '/' .. nRoad)
check(nSpot > 5 and okSpot == nSpot, 'départ sur place/allée : avant vers la route côté GPS', okSpot .. '/' .. nSpot)
check(nHome > 5 and okHome == nHome, 'départ en fond d allée : avant vers la rue', okHome .. '/' .. nHome)

print('-- pickMission (fixed start)')
local from = {x = 5, y = 3, z = 10}
from.e, from.t, from.off = graph.nearestEdge(g, from.x, from.y, from.z, 100)
local ctx = {}
for k, v in pairs(base) do ctx[k] = v end
ctx.from = from
ctx.minD, ctx.maxD = 400, 600
local res = loc.pickMission(ctx)
check(res and res.dest and not res.pickup, 'fixed start returns destination only')
check(res and res.dist >= 400 and res.dist <= 600, 'fixed start distance in range', res and res.dist)

print('-- relaxed when range impossible')
ctx = {}
for k, v in pairs(base) do ctx[k] = v end
ctx.minD, ctx.maxD = 40000, 50000
res = loc.pickMission(ctx)
check(res and res.relaxed, 'relaxed result when range too far', res and res.dist)

print('-- isFree callback')
ctx = {}
for k, v in pairs(base) do ctx[k] = v end
local calls = 0
ctx.isFree = function(zone, c) calls = calls + 1; return calls % 3 == 0 end
res = loc.pickMission(ctx)
check(res ~= nil and calls >= 3, 'occupied zones skipped', calls)

print('-- custom mode')
local pts = {
  {id = 1, name = 'Maison', pos = {x = 0, y = 125, z = 10}, dir = {x = 0, y = 1, z = 0}},
}
local cc = loc.attachCustom(g, pts)
ctx = {g = g, cands = cc, customMode = true, minD = 100, maxD = 2000, vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1, rng = rng}
local r1, why1 = loc.pickMission(ctx)
check(r1 == nil and why1 == 'need_points', 'need 2 points', why1)
pts[2] = {id = 2, name = 'Boulot', pos = {x = 600, y = 480, z = 10}, dir = {x = 1, y = 0, z = 0}}
pts[3] = {id = 3, name = 'Sans route', pos = {x = 9000, y = 9000, z = 10}, dir = {x = 1, y = 0, z = 0}}
cc = loc.attachCustom(g, pts)
check(cc[3].e == nil, 'point far from roads not attached')
ctx.cands = cc
local seenPairs = {}
for run = 1, 30 do
  local r = loc.pickMission(ctx)
  check(r ~= nil, 'custom mission found')
  if r then
    check(r.pickup.kind == 'custom' and r.dest.kind == 'custom', 'custom kinds')
    check(r.pickup ~= r.dest, 'different points')
    seenPairs[r.pickup.pointId .. '>' .. r.dest.pointId] = true
    check(approx(r.destZone.fx, r.dest.fx) and approx(r.destZone.fy, r.dest.fy), 'custom zone keeps saved direction')
  end
end
local np = 0 for _ in pairs(seenPairs) do np = np + 1 end
check(np >= 2, 'several custom pairs used', np)

print('-- temps limite selon la difficulté (timing)')
local timing = require('/lua/ge/extensions/livraisonLibre/timing')
-- trajets synthétiques : ligne droite rapide et route sinueuse de même longueur
local function straight(len, speed)
  local pts = {}
  for i = 0, len / 50 do pts[#pts + 1] = {x = i * 50, y = 0, z = 0, speed = speed, drv = 1, r = 5} end
  return pts
end
local function winding(len, speed)
  local pts, x, y, h = {}, 0, 0, 0
  local n = math.floor(len / 20)
  for i = 0, n do
    pts[#pts + 1] = {x = x, y = y, z = 0, speed = speed, drv = 1, r = 3}
    h = h + ((math.floor(i / 6) % 2 == 0) and 0.25 or -0.25) -- virages serrés alternés
    x, y = x + 20 * math.cos(h), y + 20 * math.sin(h)
  end
  return pts
end
local sports = timing.vehicleModel({top = 83.9, z100 = 4.9, brakeG = 1.13, height = 1.11}, 'sport')
local sedan = timing.vehicleModel({top = 52, z100 = 10.5, brakeG = 1.05, height = 1.4}, 'berline')
local bus = timing.vehicleModel({top = 28.5, z100 = 49.1, brakeG = 0.88, height = 3.0}, 'bus')
local unknown = timing.vehicleModel(nil, nil)
check(unknown.vt > 0 and unknown.A > 0 and unknown.aBrk > 0 and unknown.aLat > 0, 'véhicule sans infos : valeurs par défaut')
check(bus.aLat < sedan.aLat and sedan.A > bus.A and sports.A > sedan.A, 'modèle cohérent (bus moins agile, sportive plus rapide)')
local hw, tw = straight(3000, 27), winding(3000, 22)
for _, route in ipairs({{'ligne droite', hw}, {'route sinueuse', tw}}) do
  for _, veh in ipairs({{'sportive', sports}, {'berline', sedan}, {'bus', bus}}) do
    local prev
    local mono = true
    for _, L in ipairs(timing.LEVELS) do
      local t = timing.estimate(route[2], veh[2], L.id)
      if not t or t <= 0 or (prev and t >= prev) then mono = false end
      prev = t
    end
    check(mono, 'plus le niveau est dur, moins on a de temps (' .. route[1] .. ', ' .. veh[1] .. ')')
  end
end
for _, lvl in ipairs({'facile', 'dur', 'impossible'}) do
  check(timing.estimate(tw, sedan, lvl) > timing.estimate(hw, sedan, lvl) * 1.1, 'route sinueuse plus lente que ligne droite (' .. lvl .. ')')
  check(timing.estimate(hw, bus, lvl) > timing.estimate(hw, sports, lvl), 'bus plus lent que sportive (' .. lvl .. ')')
end
local tEasy, dist = timing.estimate(hw, sedan, 'tres_facile')
local tPro = timing.estimate(hw, sedan, 'impossible')
local vEasy, vPro = dist / tEasy * 3.6, dist / tPro * 3.6
check(vEasy > 20 and vEasy < 70 and vPro > 90 and vPro < 200, 'vitesses moyennes plausibles en ligne droite', string.format('%.0f / %.0f km/h', vEasy, vPro))
check(dist > 2900 and dist < 2960, 'les 50 derniers mètres ne sont pas chronométrés', dist)
check(timing.estimate({}, sedan, 'moyen') == nil and timing.estimate(nil, sedan, 'moyen') == nil, 'trajet invalide : nil')
local short = timing.estimate(straight(60, 14), sedan, 'moyen')
check(short and short > 0, 'trajet très court : temps quand même')
check(timing.fallback(3000, 'moyen') > timing.fallback(3000, 'impossible'), 'secours sans trajet')

print('-- largeur de la route')
check(timing.byId.dur.label == 'Difficile' and timing.byId.tres_dur.label == 'Très difficile', 'niveaux renommés (Difficile, Très difficile)')
local function widened(pts, r)
  local out = {}
  for i, p in ipairs(pts) do out[i] = {x = p.x, y = p.y, z = p.z, speed = p.speed, drv = p.drv, r = r} end
  return out
end
for _, route in ipairs({{'ligne droite', straight(3000, 22)}, {'route sinueuse', winding(3000, 22)}}) do
  local narrow, normal, wide = widened(route[2], 1.75), widened(route[2], 4), widened(route[2], 7)
  for _, lvl in ipairs({'moyen', 'dur', 'tres_dur', 'impossible'}) do
    local tn, tm, tw = timing.estimate(narrow, sedan, lvl), timing.estimate(normal, sedan, lvl), timing.estimate(wide, sedan, lvl)
    -- (en ligne droite, une voiture déjà à sa vitesse max ne va pas plus vite sur une route encore plus large)
    check(tn > tm and tm >= tw and tn > tw, 'route large jamais plus lente, route étroite plus lente (' .. route[1] .. ', ' .. lvl .. ')',
      string.format('%.0f / %.0f / %.0f s', tn, tm, tw))
  end
  -- un débutant reste sous la limitation : la largeur compte peu
  local en, ew = timing.estimate(narrow, sedan, 'tres_facile'), timing.estimate(wide, sedan, 'tres_facile')
  check(math.abs(en - ew) / en < 0.12, 'très facile : la largeur change peu le temps (' .. route[1] .. ')', string.format('%.0f / %.0f s', en, ew))
  -- mais même pour un débutant, une route large n'est jamais plus lente
  for _, lvl in ipairs({'tres_facile', 'facile'}) do
    local tn, tw = timing.estimate(narrow, sedan, lvl), timing.estimate(wide, sedan, lvl)
    check(tn > tw, 'route large plus rapide aussi en ' .. lvl .. ' (' .. route[1] .. ')', string.format('%.0f / %.0f s', tn, tw))
  end
end
-- un niveau plus dur ne donne jamais plus de temps, quels que soient la route, sa largeur et le véhicule
do
  local bad = {}
  for _, veh in ipairs({{'sport', sports}, {'berline', sedan}, {'bus', bus}}) do
    for _, shape in ipairs({{'droite', straight}, {'sinueuse', winding}}) do
      for _, speed in ipairs({8, 14, 22, 30, 36.1, 38.9}) do
        for _, r in ipairs({1.25, 2, 4, 7, 12}) do
          local pts = widened(shape[2](5000, speed), r)
          local prev
          for _, L in ipairs(timing.LEVELS) do
            local t = timing.estimate(pts, veh[2], L.id)
            if prev and t > prev + 1e-6 then
              bad[#bad + 1] = string.format('%s %s %.0f m/s r=%.2f %s', veh[1], shape[1], speed, r, L.id)
            end
            prev = t
          end
        end
      end
    end
  end
  check(#bad == 0, 'niveau plus dur : jamais plus de temps (180 cas)', bad[1])
end
check(timing.access(0, 'moyen') == 0 and timing.access(nil, 'moyen') == 0 and timing.access(0 / 0, 'moyen') == 0, 'hors route : rien à ajouter sans distance')
check(timing.access(100, 'tres_facile') > timing.access(100, 'impossible') and timing.access(100, 'moyen') > 10, 'hors route : roulé lentement, plus vite en impossible',
  string.format('%.1f s', timing.access(100, 'moyen')))
-- progression régulière entre niveaux (pas de saut énorme)
for _, route in ipairs({straight(3000, 22), winding(3000, 22)}) do
  local prev
  local smooth = true
  for _, L in ipairs(timing.LEVELS) do
    local t = timing.estimate(route, sedan, L.id)
    if prev and (prev / t > 1.8 or prev / t < 1.02) then smooth = false end
    prev = t
  end
  check(smooth, 'écart régulier d un niveau à l autre')
end

print('-- carrefours, ville et trafic')
-- même trajet avec des carrefours tous les 100 m (ville), tous les 600 m (campagne) ou aucun
local function withJunctions(pts, every)
  local out = {}
  for i, p in ipairs(pts) do
    out[i] = {x = p.x, y = p.y, z = p.z, speed = p.speed, drv = p.drv, r = p.r,
      deg = (every and i > 1 and i < #pts and ((i - 1) * 50) % every == 0) and 3 or 2}
  end
  return out
end
local plain, town, rural = withJunctions(straight(3000, 15)), withJunctions(straight(3000, 15), 100), withJunctions(straight(3000, 15), 600)
for _, L in ipairs(timing.LEVELS) do
  local tp, tt, tr = timing.estimate(plain, sedan, L.id), timing.estimate(town, sedan, L.id), timing.estimate(rural, sedan, L.id)
  check(tt > tp * 1.05, 'ville (carrefour tous les 100 m) : plus lent (' .. L.id .. ')', string.format('%.0f / %.0f s', tp, tt))
  check(math.abs(tr - tp) < 0.01, 'carrefours isolés à la campagne : pas de ralentissement (' .. L.id .. ')', string.format('%.1f / %.1f s', tp, tr))
  local tTraffic = timing.estimate(town, sedan, L.id, {traffic = 1})
  check(tTraffic > tt, 'trafic : plus lent en ville (carrefours) (' .. L.id .. ')', string.format('%.0f / %.0f s', tt, tTraffic))
  local tPlainTraffic = timing.estimate(plain, sedan, L.id, {traffic = 1})
  if L.id == 'tres_facile' then
    check(math.abs(tPlainTraffic - tp) < 0.01, 'trafic : pas plus vite que les voitures, pas gêné (' .. L.id .. ')', string.format('%.1f / %.1f s', tp, tPlainTraffic))
  elseif L.limit > 1 then
    check(tPlainTraffic > tp, 'trafic : on rattrape les voitures, plus lent (' .. L.id .. ')', string.format('%.1f / %.1f s', tp, tPlainTraffic))
  else
    check(tPlainTraffic >= tp, 'trafic : jamais plus rapide (' .. L.id .. ')')
  end
end
-- passer entre les voitures ou se rabattre : largeur des voies, du véhicule, et une vraie marge
check(timing.trafficBlock(7, 2, false, 1.9, false) > timing.trafficBlock(12, 2, false, 1.9, false), 'route large : on passe entre les voitures')
check(timing.trafficBlock(11, 2, false, 1.9, false) < timing.trafficBlock(11, 2, false, 2.55, false), 'même route : une voiture passe, un bus non')
check(timing.trafficBlock(7.8, 2, false, 1.9, false) > timing.trafficBlock(7.8, 2, false, 0.9, false), 'petit véhicule : passe plus souvent')
do
  -- ça passerait à 1 mm près : non, il faut la marge
  local tight = (2.0 + 1.9 + 0.001) * 2          -- l'écart entre les deux voitures = le véhicule + 1 mm
  local roomy = (2.0 + 1.9 + 2 * 0.5 + 0.001) * 2 -- le véhicule + 50 cm de chaque côté
  check(timing.trafficBlock(tight, 2, false, 1.9, false) > timing.trafficBlock(roomy, 2, false, 1.9, false), 'pas de passage au millimètre : il faut une marge de chaque côté')
end
check(timing.trafficBlock(14, 4, false, 1.9, false) < timing.trafficBlock(7, 2, false, 1.9, false), 'deux voies dans son sens : on double en changeant de voie')
check(timing.trafficBlock(4, 1, true, 1.9, false) > timing.trafficBlock(7, 2, false, 1.9, false), 'sens unique à une voie : coincé derrière')
check(timing.trafficBlock(7, 2, false, 1.9, true) > timing.trafficBlock(7, 2, false, 1.9, false), 'en ville : plus de voitures en face, on double moins')
check(timing.trafficBlock(7, 0, false, 1.9, false) == timing.trafficBlock(7, 2, false, 1.9, false), 'nombre de voies inconnu : déduit de la largeur')
do
  local function laned(pts, r, lanes)
    local out = widened(pts, r)
    for _, p in ipairs(out) do p.lanes = lanes end
    return out
  end
  local narrow = laned(straight(3000, 15), 3.5, 2) -- 7 m, deux voies : on se rabat
  local wide = laned(straight(3000, 15), 5.5, 2)   -- 11 m, deux voies : une voiture passe entre, un véhicule de 2,6 m non
  local function loss(pts, vehW)
    return timing.estimate(pts, sedan, 'tres_dur', {traffic = 1, vehW = vehW}) / timing.estimate(pts, sedan, 'tres_dur')
  end
  check(loss(wide, 1.9) < loss(narrow, 1.9), 'trafic : moins de temps perdu sur une route assez large pour passer', string.format('%.3f / %.3f', loss(wide, 1.9), loss(narrow, 1.9)))
  check(loss(wide, 2.6) > loss(wide, 1.9), 'trafic : un véhicule large perd plus de temps', string.format('%.3f / %.3f', loss(wide, 2.6), loss(wide, 1.9)))
end
check(timing.trafficDensity(0) == 0 and timing.trafficDensity(nil) == 0 and timing.trafficDensity(0 / 0) == 0, 'pas de trafic : densité 0')
check(timing.trafficDensity(10) == 1 and timing.trafficDensity(5) == 0.5 and timing.trafficDensity(200) == 1.5, 'densité selon le nombre de véhicules (plafonnée)')
-- toujours un niveau plus dur = moins de temps, en ville et avec du trafic
do
  local bad
  for _, veh in ipairs({{'sport', sports}, {'berline', sedan}, {'bus', bus}}) do
    for _, every in ipairs({100, 150, 600}) do
      for _, traffic in ipairs({0, 1, 1.5}) do
        local pts = withJunctions(winding(4000, 14), every)
        local prev
        for _, L in ipairs(timing.LEVELS) do
          local t = timing.estimate(pts, veh[2], L.id, {traffic = traffic})
          if prev and t > prev + 1e-6 then bad = bad or string.format('%s %d m trafic %.1f %s', veh[1], every, traffic, L.id) end
          prev = t
        end
      end
    end
  end
  check(bad == nil, 'en ville et avec trafic : niveau plus dur = jamais plus de temps', bad)
end
-- chrono jusqu'à la validation
check(timing.fullChrono('tres_dur') and timing.fullChrono('impossible'), 'très difficile et impossible : chrono jusqu à la validation')
check(not timing.fullChrono('dur') and not timing.fullChrono('moyen') and not timing.fullChrono('n_importe_quoi'), 'autres niveaux : non (sauf option)')
do
  local ok, prev = true, nil
  for _, L in ipairs(timing.LEVELS) do
    local p = timing.parkTime(L.id)
    if p <= 5 or (prev and p > prev) then ok = false end
    prev = p
  end
  check(ok, 'temps de stationnement : plus court quand la difficulté monte')
end
check(timing.parkTime('dur', true) > timing.parkTime('dur', false), 'validation automatique : temps d attente compté')

print('-- pentes')
-- pente constante le long de la route (altitude = pente x distance parcourue)
local function sloped(pts, grade)
  local out, s = {}, 0
  for i, p in ipairs(pts) do
    if i > 1 then s = s + math.sqrt((p.x - pts[i - 1].x) ^ 2 + (p.y - pts[i - 1].y) ^ 2) end
    out[i] = {x = p.x, y = p.y, z = s * grade, speed = p.speed, drv = p.drv, r = p.r}
  end
  return out
end
do
  local flat8, up8 = straight(3000, 22), sloped(straight(3000, 22), 0.08)
  local okBus, okSedan = true, true
  for _, L in ipairs(timing.LEVELS) do
    if not (timing.estimate(up8, bus, L.id) > timing.estimate(flat8, bus, L.id) * 1.02) then okBus = false end
    if timing.estimate(up8, sedan, L.id) < timing.estimate(flat8, sedan, L.id) - 1e-6 then okSedan = false end
  end
  check(okBus, 'côte de 8 % : un bus monte nettement moins vite')
  check(okSedan, 'côte de 8 % : jamais plus rapide qu à plat')
  local lossBus = timing.estimate(up8, bus, 'dur') / timing.estimate(flat8, bus, 'dur')
  local lossSport = timing.estimate(up8, sports, 'dur') / timing.estimate(flat8, sports, 'dur')
  check(lossBus > lossSport, 'côte : un véhicule peu puissant perd plus qu une sportive', string.format('%.2f / %.2f', lossBus, lossSport))
  -- côte trop raide pour le moteur : on monte quand même, au pas
  local wall = sloped(straight(500, 22), 0.30)
  local tw = timing.estimate(wall, bus, 'moyen')
  check(tw and tw < math.huge and tw > timing.estimate(straight(500, 22), bus, 'moyen'), 'côte très raide : temps fini (au pas), plus long qu à plat', tw)
  check(tw < 500 / 4 * 1.3 * timing.byId.moyen.margin, 'côte très raide : jamais plus lent que le pas', tw)
  -- descente raide et sinueuse : prudence et freinages plus longs
  local wf, wd = winding(3000, 22), sloped(winding(3000, 22), -0.10)
  check(timing.estimate(wd, sedan, 'tres_facile') > timing.estimate(wf, sedan, 'tres_facile') * 1.03, 'descente raide : un débutant lève le pied')
  check(timing.estimate(wd, sedan, 'dur') > timing.estimate(wf, sedan, 'dur'), 'descente raide et virages : freinages plus longs')
  -- donnée aberrante (saut de 100 m d'altitude en 5 m) : pente plafonnée, pas de temps absurde
  local spike = straight(1000, 22)
  spike[10].z = 100
  local ts, tf0 = timing.estimate(spike, sedan, 'moyen'), timing.estimate(straight(1000, 22), sedan, 'moyen')
  check(ts and ts < tf0 * 2, 'pente aberrante plafonnée', string.format('%.0f / %.0f s', ts or -1, tf0))
  -- toujours : niveau plus dur = moins de temps, en côte comme en descente
  local bad
  for _, veh in ipairs({{'sport', sports}, {'berline', sedan}, {'bus', bus}}) do
    for _, grade in ipairs({-0.12, -0.06, 0.06, 0.12}) do
      for _, shape in ipairs({straight, winding}) do
        local pts = sloped(shape(3000, 20), grade)
        local prev
        for _, L in ipairs(timing.LEVELS) do
          local t = timing.estimate(pts, veh[2], L.id, {traffic = 1})
          if prev and t > prev + 1e-6 then bad = bad or string.format('%s pente %.2f %s', veh[1], grade, L.id) end
          prev = t
        end
      end
    end
  end
  check(bad == nil, 'en côte et en descente : niveau plus dur = jamais plus de temps', bad)
end

print('-- bretelles de voie rapide : pas des carrefours')
do
  -- voie rapide à sens unique vers +x (120 km/h) avec une sortie et une entrée en biais tous les 200 m,
  -- et un seul vrai croisement (une rue à double sens) au milieu
  local nodes = {}
  local function node(id, x, y) nodes[id] = {pos = {x = x, y = y, z = 10}, radius = 6, links = {}, normal = {x = 0, y = 0, z = 1}} end
  local function link(a, b, data)
    data = data or {}
    data.drivability = 1
    data.inNode = data.inNode or a
    local outNode = (data.inNode == a) and b or a
    nodes[outNode].links[data.inNode] = data
  end
  for i = 0, 15 do node('f' .. i, i * 200, 0) end
  for i = 0, 14 do link('f' .. i, 'f' .. (i + 1), {oneWay = true, inNode = 'f' .. i, speedLimit = 33.3, lanes = '++'}) end
  for i = 1, 14 do
    if i ~= 8 then
      node('off' .. i, i * 200 + 60, -25); link('f' .. i, 'off' .. i, {oneWay = true, inNode = 'f' .. i, speedLimit = 20})
      node('on' .. i, i * 200 - 60, -25); link('on' .. i, 'f' .. i, {oneWay = true, inNode = 'on' .. i, speedLimit = 20})
    end
  end
  node('rue', 8 * 200, 120); link('f8', 'rue', {speedLimit = 14})
  local gf = graph.build(nodes)
  local function edgeOf(a, b)
    local ia, ib = gf.idx[a], gf.idx[b]
    for _, ei in ipairs(gf.adj[ia]) do local e = gf.edges[ei] if (e.a == ia and e.b == ib) or (e.a == ib and e.b == ia) then return ei, e.a == ia end end
  end
  local e1, fwd1 = edgeOf('f0', 'f1')
  local e2, fwd2 = edgeOf('f14', 'f15')
  local pts = graph.route(gf, {e = e1, t = fwd1 and 0 or 1}, {e = e2, t = fwd2 and 1 or 0})
  local nJn, nDeg = 0, 0
  for k = 2, #(pts or {}) - 1 do
    if pts[k].jn then nJn = nJn + 1 end
    if (pts[k].deg or 0) >= 3 then nDeg = nDeg + 1 end
  end
  check(pts and nDeg >= 13 and nJn == 1, 'voie rapide : bretelles ignorées, seul le vrai croisement compte', string.format('%d noeuds à 3 routes, %d carrefours', nDeg, nJn))
  -- même temps qu'une voie rapide sans bretelle (le croisement seul, isolé, ne ralentit pas)
  local plain = {}
  for k, p in ipairs(pts or {}) do plain[k] = {x = p.x, y = p.y, z = p.z, speed = p.speed, drv = p.drv, r = p.r, lanes = p.lanes, oneWay = p.oneWay} end
  local sedanF = timing.vehicleModel({top = 60, z100 = 8, brakeG = 1.05, height = 1.4}, 'berline')
  for _, lvl in ipairs({'facile', 'dur', 'tres_dur'}) do
    local tr, tp = timing.estimate(pts, sedanF, lvl), timing.estimate(plain, sedanF, lvl)
    check(math.abs(tr - tp) < 0.01, 'voie rapide avec bretelles : pas ralentie (' .. lvl .. ')', string.format('%.1f / %.1f s', tr, tp))
  end
end

print('-- comportement du véhicule (drifteuse / accrocheuse)')
do
  local base = {top = 60, z100 = 5.5, brakeG = 1.1, height = 1.35, power = 400, weight = 1500}
  local function with(extra) local p = {} for k, v in pairs(base) do p[k] = v end for k, v in pairs(extra) do p[k] = v end return timing.vehicleModel(p, 'coupe') end
  local awd, fwd, rwd = with({drive = 'AWD'}), with({drive = 'FWD'}), with({drive = 'RWD'})
  local drift = with({drive = 'RWD', cfgType = 'Drift'})
  local calm = timing.vehicleModel({top = 52, z100 = 10.9, brakeG = 1.07, height = 1.4, power = 124, weight = 1315, drive = 'FWD'}, 'berline')
  check(awd.stab >= 0.95 and awd.share > rwd.share, '4 roues motrices : accroche, meilleure motricité', awd.stab)
  check(rwd.stab < fwd.stab and rwd.stab < awd.stab, 'propulsion puissante : glisse plus', string.format('%.2f / %.2f / %.2f', awd.stab, fwd.stab, rwd.stab))
  check(drift.stab <= 0.72 and drift.stab < rwd.stab + 1e-9, 'config de drift : glisse', drift.stab)
  check(calm.stab > 0.95, 'petite traction : stable', calm.stab)
  local twisty, line = winding(3000, 22), straight(3000, 22)
  for _, lvl in ipairs({'dur', 'impossible'}) do
    local tA, tR, tD = timing.estimate(twisty, awd, lvl), timing.estimate(twisty, rwd, lvl), timing.estimate(twisty, drift, lvl)
    check(tA < tR and tR <= tD, 'routes sinueuses : 4 roues motrices > propulsion > drift (' .. lvl .. ')', string.format('%.0f / %.0f / %.0f s', tA, tR, tD))
    local sA, sR = timing.estimate(line, awd, lvl), timing.estimate(line, rwd, lvl)
    check(math.abs(sA - sR) / sA < 0.05, 'ligne droite : la transmission compte peu (' .. lvl .. ')', string.format('%.1f / %.1f s', sA, sR))
  end
  -- terre : les pneus tout-terrain gardent plus d'adhérence
  local dirtRoad = {}
  for i, p in ipairs(winding(3000, 15)) do dirtRoad[i] = {x = p.x, y = p.y, z = p.z, speed = p.speed, drv = 0.4, r = p.r} end
  local road4x4 = with({drive = 'AWD', offroad = 80})
  local roadCar = with({drive = 'AWD', offroad = 20})
  check(timing.estimate(dirtRoad, road4x4, 'dur') < timing.estimate(dirtRoad, roadCar, 'dur'), 'terre : pneus tout-terrain plus rapides')
  check(math.abs(timing.estimate(twisty, road4x4, 'dur') - timing.estimate(twisty, roadCar, 'dur')) < 1e-6, 'bitume : les pneus tout-terrain ne changent rien (adhérence déjà dans le freinage mesuré)')
  -- freinage en plein virage : on ne freine pas à fond en tournant
  check(timing.estimate(twisty, awd, 'impossible') > timing.estimate(twisty, {vt = awd.vt, A = awd.A, aBrk = awd.aBrk, aLat = awd.aLat, stab = 1, share = 5, dirt = awd.dirt}, 'impossible') - 1e-6,
    'cercle d adhérence : jamais plus rapide qu un véhicule sans limite de motricité')
end
do
  local vehLib = require('/lua/ge/extensions/livraisonLibre/vehicles')
  local cls = vehLib.classify({model_key = 'x', key = 'drift', pcFilename = '/vehicles/x/drift.pc', Name = 'X drift', Drivetrain = 'RWD', ['Config Type'] = 'Drift', ['Off-Road Score'] = 25,
    Power = 518, Weight = 1775, ['Top Speed'] = 54.6, ['0-100 km/h'] = 7.3, ['Braking G'] = 1.12}, {Type = 'Car', ['Body Style'] = 'Sedan'})
  check(cls and cls.perf.drive == 'RWD' and cls.perf.cfgType == 'Drift' and cls.perf.offroad == 25, 'fiche du véhicule : transmission, type de config, score tout-terrain lus',
    cls and string.format('%s / %s / %s', tostring(cls.perf.drive), tostring(cls.perf.cfgType), tostring(cls.perf.offroad)))
end

print('-- trajet routier (graph.route)')
local gr = graph.build((citygen.city(9, 120)))
local spots = loc.buildRoadSpots(gr)
print('-- carrefours dans le trajet')
do
  local found = false
  for i = 1, 20 do
    local a, b = spots[(i * 7) % #spots + 1], spots[(i * 13 + 5) % #spots + 1]
    local pts = graph.route(gr, a, b)
    if pts then
      for k = 2, #pts - 1 do if (pts[k].deg or 0) >= 3 then found = true end end
    end
  end
  check(found, 'graph.route : carrefours repérés (noeuds où 3 routes ou plus se rejoignent)')
end

local okRoutes, linked = 0, 0
for i = 1, 30 do
  local a, b = spots[(i * 7) % #spots + 1], spots[(i * 13) % #spots + 1]
  local pts = graph.route(gr, a, b)
  local reachable = loc.candDist(gr, graph.dijkstra(gr, graph.sourcesFor(gr, a.e, a.t, 0)), b, a) ~= nil
  if reachable then linked = linked + 1 end
  if not reachable and pts == nil then okRoutes = okRoutes + 1 end -- deux zones non reliées : pas de trajet
  if pts then
    local len = 0
    for k = 1, #pts - 1 do len = len + math.sqrt((pts[k + 1].x - pts[k].x) ^ 2 + (pts[k + 1].y - pts[k].y) ^ 2 + (pts[k + 1].z - pts[k].z) ^ 2) end
    -- même longueur que la distance routière dans le sens de circulation
    local d = loc.candDist(gr, graph.dijkstra(gr, graph.sourcesFor(gr, a.e, a.t, 0, 1), nil, nil, 1), b, a, 1)
    local startOk = math.abs(pts[1].x - a.x) < 0.01 and math.abs(pts[1].y - a.y) < 0.01
    local endOk = math.abs(pts[#pts].x - b.x) < 0.01 and math.abs(pts[#pts].y - b.y) < 0.01
    if startOk and endOk and d and math.abs(len - d) < 1 then okRoutes = okRoutes + 1 end
  end
end
check(okRoutes == 30 and linked >= 20, 'trajet du départ à l arrivée, de la même longueur que la distance routière (ou aucun si non relié)', okRoutes .. '/' .. linked)

print('-- sens uniques : trajet dans le sens de circulation (comme le GPS)')
local function routeLen(pts)
  local len = 0
  for k = 1, pts and #pts - 1 or 0 do len = len + math.sqrt((pts[k + 1].x - pts[k].x) ^ 2 + (pts[k + 1].y - pts[k].y) ^ 2 + (pts[k + 1].z - pts[k].z) ^ 2) end
  return len
end
do
  -- citygen : la rangée y = 480 est à sens unique vers +x
  local g9 = graph.build((citygen.city(9, 120)))
  local function at(x, y)
    local ei, t = graph.nearestEdge(g9, x, y, 10, 20)
    return {e = ei, t = t, off = 0, x = x, y = y, z = 10}
  end
  local w, e9 = g9.idx['g2_4'], g9.edges[at(300, 480).e]
  check(e9.oneWay and e9.inNode == w, 'sens unique : inNode = noeud d entrée (côté ouest)', e9.inNode)
  local A, B = at(900, 480), at(300, 480)
  local undirected = loc.candDist(g9, graph.dijkstra(g9, graph.sourcesFor(g9, A.e, A.t, 0)), B, A)
  local fwd = graph.dijkstra(g9, graph.sourcesFor(g9, A.e, A.t, 0, 1), nil, nil, 1)
  local legal = loc.candDist(g9, fwd, B, A, 1)
  check(approx(undirected, 600, 1e-6), 'sans les sens uniques : 600 m à contresens', undirected)
  check(legal and approx(legal, 1080, 1e-6), 'x=900 -> x=300 : 1080 m par le tour du pâté de maisons', legal)
  local pts = graph.route(g9, A, B)
  check(pts and approx(routeLen(pts), 1080, 1e-6), 'graph.route suit le sens de circulation (temps limite)', pts and routeLen(pts))
  local wrong = false
  for k = 1, pts and #pts - 1 or 0 do
    if math.abs(pts[k].y - 480) < 1e-6 and math.abs(pts[k + 1].y - 480) < 1e-6 and pts[k + 1].x < pts[k].x - 1e-6 then wrong = true end
  end
  check(pts and not wrong, 'aucun tronçon du trajet à contresens')
  -- dans le bon sens : tout droit
  local back = graph.route(g9, B, A)
  check(back and #back == 7 and approx(routeLen(back), 600, 1e-6), 'x=300 -> x=900 : 600 m tout droit', back and routeLen(back))
  -- même segment : direct dans le sens légal, sinon le tour
  local s1, s2 = at(310, 480), at(350, 480)
  check(approx(routeLen(graph.route(g9, s1, s2)), 40, 1e-6), 'même segment dans le bon sens : direct')
  check(approx(loc.candDist(g9, graph.dijkstra(g9, graph.sourcesFor(g9, s2.e, s2.t, 0, 1), nil, nil, 1), s1, s2, 1), 440, 1e-6),
    'même segment à contresens : le tour (440 m)')
  check(approx(routeLen(graph.route(g9, s2, s1)), 440, 1e-6), 'graph.route même segment à contresens : le tour')
  -- recherche à rebours : distance légale de chaque noeud jusqu'à l'arrivée
  local rev = graph.dijkstra(g9, graph.sourcesFor(g9, B.e, B.t, 0, -1), nil, nil, -1)
  check(approx(graph.pointDist(g9, rev, A.e, A.t, 0, -1), 1080, 1e-6), 'à rebours depuis l arrivée : même distance légale')
  check(approx(rev[g9.idx['g1_4']], 180, 1e-6) and approx(rev[g9.idx['g3_4']], 420, 1e-6), 'à rebours : on n arrive que par l entrée du sens unique',
    tostring(rev[g9.idx['g1_4']]) .. ' / ' .. tostring(rev[g9.idx['g3_4']]))
  -- borne : capped
  local _, cappedB = graph.dijkstra(g9, graph.sourcesFor(g9, A.e, A.t, 0, 1), 300, nil, 1)
  local _, cappedU = graph.dijkstra(g9, graph.sourcesFor(g9, A.e, A.t, 0, 1), nil, nil, 1)
  check(cappedB == true and cappedU == false, 'dijkstra signale quand la borne coupe la recherche')

  -- départ fixe sur le sens unique : distances annoncées = trajet du GPS
  local road9 = loc.buildRoadSpots(g9)
  local bad, n = 0, 0
  for run = 1, 40 do
    local ctx = {g = g9, cands = road9, minD = 550, maxD = 650, vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1, rng = rng,
      filter = {kinds = {road = true}}, from = A}
    local res = loc.pickMission(ctx)
    if res then
      n = n + 1
      local rp = graph.route(g9, A, res.dest)
      if math.abs(routeLen(rp) - res.dist) > 0.01 or res.dist < 550 or res.dist > 650 then bad = bad + 1 end
      for k = 1, #rp - 1 do -- jamais à contresens sur la rangée y = 480
        if math.abs(rp[k].y - 480) < 1e-6 and math.abs(rp[k + 1].y - 480) < 1e-6 and rp[k + 1].x < rp[k].x - 1e-6 then bad = bad + 1 end
      end
    end
  end
  check(n == 40 and bad == 0, 'départ fixe : destination à la bonne distance par le trajet légal', n .. ' / ' .. bad)

  -- place de parking le long du sens unique : le véhicule repart dans le sens légal
  local att9 = loc.attachSpots(g9, {{name = 'ow', kind = 'parking', x = 300, y = 488, z = 10, fx = -1, fy = 0, fz = 0, w = 2.5, l = 6}})
  local sp = att9[1]
  local dest = at(60, 600) -- au nord-ouest : plus court par l'ouest, mais c'est à contresens
  local pz = loc.zoneFor(sp, 2, 4.8, 1.3, 1, 1)
  local oz = loc.orientPickup(g9, sp, pz, dest, {vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1}, 1e9)
  check(sp and pz.fx < 0 and oz.fx > 0, 'départ d une place sur un sens unique : avant dans le sens de circulation', oz and oz.fx)
end

print('-- sens uniques sans issue (données de map incohérentes) : secours')
do
  -- une ligne de 6 noeuds, tout en sens unique vers +x : impossible de revenir vers l'ouest légalement
  local nodes = {}
  for k = 0, 5 do nodes['n' .. k] = {pos = {x = k * 100, y = 0, z = 10}, radius = 4, links = {}, normal = {x = 0, y = 0, z = 1}} end
  for k = 0, 4 do
    local a, b = 'n' .. k, 'n' .. (k + 1)
    nodes[b].links[a] = {drivability = 1, oneWay = true, inNode = a, outNode = b}
  end
  local gl = graph.build(nodes)
  local spotsL = loc.buildRoadSpots(gl)
  local function near(x)
    local best
    for _, c in ipairs(spotsL) do if not best or math.abs(c.x - x) < math.abs(best.x - x) then best = c end end
    return best
  end
  local east, west = near(450), near(50)
  check(east and west and east ~= west, 'emplacements sur la ligne', #spotsL)
  local straightLen = east.x - west.x
  local pts = graph.route(gl, east, west)
  check(pts and approx(routeLen(pts), straightLen, 1e-6), 'pas de trajet légal : graph.route se rabat sur le trajet sans sens uniques', pts and routeLen(pts))
  check(approx(routeLen(graph.route(gl, west, east)), straightLen, 1e-6), 'dans le bon sens : trajet normal')
  -- départ coincé au bout de la ligne : la mission reste possible, à la bonne distance
  local from = {x = east.x, y = east.y, z = east.z, e = east.e, t = east.t, off = 0}
  local ctx = {g = gl, cands = spotsL, minD = 300, maxD = 450, vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1, rng = rng,
    filter = {kinds = {road = true}}, from = from}
  local res = loc.pickMission(ctx)
  check(res and not res.relaxed and res.dist >= 300 and res.dist <= 450 and res.dest.x < east.x, 'départ coincé : destination quand même (secours)',
    res and (res.dist .. ' relaxed=' .. tostring(res.relaxed)))
  check(res and approx(routeLen(graph.route(gl, from, res.dest)), res.dist, 0.01), 'départ coincé : distance annoncée = trajet de secours')
  -- départs aléatoires : toujours une mission
  local okN = 0
  for run = 1, 30 do
    local c2 = {g = gl, cands = spotsL, minD = 200, maxD = 400, vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1, rng = rng,
      filter = {kinds = {road = true}}}
    local r = loc.pickMission(c2)
    if r and r.dist and r.pickupZone then okN = okN + 1 end
  end
  check(okN == 30, 'graphe à sens uniques sans issue : toujours une mission', okN)
  -- orientation : rien de légal, on se rabat sur le trajet sans sens uniques (vers la destination)
  local pk = loc.attachSpots(gl, {{name = 'p', kind = 'parking', x = 450, y = 8, z = 10, fx = 1, fy = 0, fz = 0, w = 2.5, l = 6}})[1]
  local pz = loc.zoneFor(pk, 2, 4.8, 1.3, 1, 1)
  local oz = loc.orientPickup(gl, pk, pz, west, {vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1}, 1e9)
  check(oz and oz.fx < 0, 'orientation de secours vers la destination', oz and oz.fx)
  -- impasse à sens unique accrochée à la ville : le départ y est coincé, mission quand même
  local cn = citygen.city(8, 120)
  cn.spur = {pos = {x = 360, y = 330, z = 10}, radius = 4, links = {}, normal = {x = 0, y = 0, z = 1}}
  cn.spur.links.g3_3 = {drivability = 1, oneWay = true, inNode = 'g3_3', outNode = 'spur'}
  local gs = graph.build(cn)
  local rs = loc.buildRoadSpots(gs)
  local ei, t = graph.nearestEdge(gs, 360, 330, 10, 5)
  local r2 = loc.pickMission({g = gs, cands = rs, minD = 400, maxD = 700, vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1, rng = rng,
    filter = {kinds = {road = true}}, from = {x = 360, y = 330, z = 10, e = ei, t = t, off = 0}})
  check(r2 and not r2.relaxed, 'départ dans une impasse à sens unique : mission à la bonne distance', r2 and r2.dist)
  local fromS = {x = 360, y = 330, z = 10, e = ei, t = t, off = 0}
  check(r2 and approx(routeLen(graph.route(gs, fromS, r2.dest)), r2.dist, 0.01), 'impasse à sens unique : distance annoncée = trajet',
    r2 and (routeLen(graph.route(gs, fromS, r2.dest)) .. ' vs ' .. r2.dist))
end

print('-- allées : profondeur jusqu au trottoir')
do
  local nodes = {}
  local function node(id, x, y, r) nodes[id] = {pos = {x = x, y = y, z = 10}, radius = r, links = {}, normal = {x = 0, y = 0, z = 1}} end
  local function link(a, b, data) data = data or {}; data.drivability = data.drivability or 1; data.inNode = a; data.outNode = b; nodes[b].links[a] = data end
  node('s0', 0, 0, 4); node('j1', 50, 0, 4); node('s2', 100, 0, 4); node('j2', 200, 0, 4); node('j3', 300, 0, 4); node('s4', 400, 0, 4)
  link('s0', 'j1'); link('j1', 's2'); link('s2', 'j2'); link('j2', 'j3'); link('j3', 's4')
  node('short', 50, 9, 2); link('j1', 'short', {type = 'private'})                    -- 9 m : 5 m après le trottoir
  node('mid', 200, 16, 2); node('deep', 200, 22, 2)                                    -- 22 m dont 6 m de dernier segment
  link('j2', 'mid', {type = 'private'}); link('mid', 'deep', {type = 'private'})
  node('med', 300, 14, 2); link('j3', 'med', {type = 'private'})                       -- 14 m : 10 m après le trottoir
  local gd = graph.build(nodes)
  local hd = loc.buildDeadEnds(gd)
  local byId = {}
  for _, h in ipairs(hd) do byId[gd.ids[(h.t == 0) and gd.edges[h.e].a or gd.edges[h.e].b]] = h end
  check(byId.short and byId.deep and byId.med and #hd == 3, 'trois allées', #hd)
  check(approx(byId.short.depth, 5) and approx(byId.deep.depth, 18) and approx(byId.med.depth, 10), 'profondeur = chaîne privée - demi-largeur de la rue',
    byId.short.depth .. ' / ' .. byId.deep.depth .. ' / ' .. byId.med.depth)
  local VEH = {sedan = {1.9, 4.7}, van = {2.1, 5.6}, md = {2.64, 8.05}, bus = {3.11, 12.63}}
  local function fitsV(h, v) return loc.fits(h, VEH[v][1], VEH[v][2], 1.3) end
  check(not fitsV(byId.short, 'sedan') and not fitsV(byId.short, 'bus'), 'allée trop courte : refusée (même pour une berline)')
  check(fitsV(byId.deep, 'sedan') and fitsV(byId.deep, 'bus'), 'allée longue au dernier segment court : berline et bus acceptés')
  check(fitsV(byId.med, 'sedan') and fitsV(byId.med, 'van') and not fitsV(byId.med, 'md') and not fitsV(byId.med, 'bus'), 'allée moyenne : berline et fourgon, pas le camion ni le bus')
  -- la zone reste dans l'allée : ni dans la maison (au-delà du fond) ni sur la rue
  local inside, total = 0, 0
  for _, h in ipairs(hd) do
    for name, v in pairs(VEH) do
      if fitsV(h, name) then
        total = total + 1
        local z = loc.zoneFor(h, v[1], v[2], 1.3, 1, 1)
        local back = (h.x - z.x) * h.fx + (h.y - z.y) * h.fy  -- recul du centre depuis le fond
        if back - z.l * 0.5 >= -1e-6 and back + z.l * 0.5 <= h.depth + 1e-6 then inside = inside + 1 end
      end
    end
  end
  check(total >= 6 and inside == total, 'zone entièrement dans l allée', inside .. '/' .. total)
  -- zone forcée (véhicule trop grand) : toujours calculée
  check(loc.zoneFor(byId.short, 3.11, 12.63, 1.3, 1, 1, true) ~= nil, 'zone forcée sur une allée trop courte')
  -- pickMission ne propose pas l'allée trop courte à un bus
  local spotsD = loc.buildRoadSpots(gd)
  local cd = {}
  for _, l in ipairs({spotsD, hd}) do for _, c in ipairs(l) do cd[#cd + 1] = c end end
  local seenShort, nMis = false, 0
  for run = 1, 40 do
    local r = loc.pickMission({g = gd, cands = cd, minD = 20, maxD = 400, vehW = 3.11, vehL = 12.63, scale = 1.3, legalSide = 1, rng = rng,
      filter = {kinds = {home = true, road = true}}})
    if r then nMis = nMis + 1 end
    if r and (r.dest == byId.short or r.pickup == byId.short) then seenShort = true end
  end
  check(nMis > 30 and not seenShort, 'bus : jamais dans une allée trop courte', nMis)
end

print('-- départs et arrivées : lieux récents évités')
do
  local cands = loc.buildRoadSpots(g)
  local avoid = {}
  local ctxA = {g = g, cands = cands, minD = 200, maxD = 900, vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1, rng = rng, avoid = avoid}
  local nearP, nearD, n = 0, 0, 0
  for _ = 1, 30 do
    local r = loc.pickMission(ctxA)
    if r then
      n = n + 1
      for _, p in ipairs(avoid) do
        if (r.pickup.x - p.x) ^ 2 + (r.pickup.y - p.y) ^ 2 < 150 ^ 2 then nearP = nearP + 1 end
        if (r.dest.x - p.x) ^ 2 + (r.dest.y - p.y) ^ 2 < 150 ^ 2 then nearD = nearD + 1 end
      end
      table.insert(avoid, 1, {x = r.pickup.x, y = r.pickup.y})
      table.insert(avoid, 1, {x = r.dest.x, y = r.dest.y})
      while #avoid > 10 do table.remove(avoid) end
    end
  end
  check(n == 30 and nearP == 0, 'nouveau départ : jamais près des 5 derniers départs et arrivées', n .. ' livraisons, ' .. nearP .. ' trop proches')
  check(nearD <= 3, 'nouvelle arrivée : presque jamais près des lieux récents', nearD)
  -- tous les lieux ont déjà servi : on trouve quand même une livraison à la bonne distance
  local all = {}
  for _, c in ipairs(cands) do all[#all + 1] = {x = c.x, y = c.y} end
  local rAll = loc.pickMission({g = g, cands = cands, minD = 200, maxD = 900, vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1, rng = rng, avoid = all})
  check(rAll ~= nil and not rAll.relaxed, 'tous les lieux déjà utilisés : livraison quand même trouvée')
end

print('-- départ en fond d allée : avant vers la rue (égalité a/b)')
do
  local ctxO = {vehW = 2, vehL = 4.8, scale = 1.3, legalSide = 1}
  local dests = loc.buildRoadSpots(g)
  local ok, n, t0n, t1n = 0, 0, 0, 0
  local function pass()
    for k, h in ipairs(loc.buildDeadEnds(g)) do
      local dest = dests[(k * 17) % #dests + 1]
      local z = loc.orientPickup(g, h, loc.zoneFor(h, 2, 4.8, 1.3, 1, 1), dest, ctxO, 1e9)
      n = n + 1
      if h.t == 0 then t0n = t0n + 1 else t1n = t1n + 1 end
      if z.fx * h.fx + z.fy * h.fy < 0 then ok = ok + 1 end
    end
  end
  pass()
  -- même chose avec les extrémités a/b des allées inversées (le fond devient l'autre extrémité)
  local function swapPrivate()
    for _, e in ipairs(g.edges) do if e.private then e.a, e.b = e.b, e.a end end
  end
  swapPrivate()
  pass()
  swapPrivate()
  check(n > 5 and t0n > 0 and t1n > 0 and ok == n, 'fond d allée en a ou en b : toujours orienté vers la rue', ok .. '/' .. n .. ' (t=0 ' .. t0n .. ', t=1 ' .. t1n .. ')')
end

print('-- boîte de vitesses d après les pièces')
do
  local veh = require('/lua/ge/extensions/livraisonLibre/vehicles')
  local function tp(slot, part) return veh.transmissionFromParts({[slot] = part}) end
  check(tp('autobello_transaxle', 'autobello_transaxle_4M') == 'manual', 'autobello 4M : manuelle (pas "auto" du nom du modèle)')
  check(tp('autobello_transaxle', 'autobello_transaxle_5M') == 'manual', 'autobello 5M : manuelle')
  check(tp('autobello_transaxle', 'autobello_sbr_transaxle_6M_SQ') == 'manual', 'autobello 6M_SQ : manuelle (séquentielle)')
  check(tp('autobuggy_transaxle', 'autobuggy_transaxle_5M_race') == 'manual', 'autobuggy 5M race : manuelle')
  check(tp('autobello_transaxle', 'autobello_transaxle') == nil, 'pièce sans suffixe : inconnue')
  check(tp('covet_transmission', 'covet_transmission_4A') == 'auto', 'covet 4A : automatique')
  check(tp('etk800_transmission', 'etk800_transmission_7DCT') == 'auto', '7DCT : automatique')
  check(tp('vivace_transmission', 'vivace_transmission_CVT') == 'auto', 'CVT : automatique')
  check(tp('scintilla_transmission', 'scintilla_transmission_sequential') == 'manual', 'séquentielle : manuelle')
  check(tp('x_transmission', 'x_transmission_sq') == 'manual', 'suffixe sq : manuelle')
  check(tp('semi_gearbox', 'semi_gearbox_18M') == 'manual', 'gearbox 18M : manuelle')
  check(tp('autobuggy_transmission', 'autobuggy_5M') == 'manual', 'sans mot-clé : le nom du modèle est ignoré')
  check(tp('pickup_transmission', 'pickup_transmission_4A_heavy') == 'auto', '4A_heavy : automatique')
  check(tp('pickup_transfer_case', 'pickup_transfer_case_auto') == nil, 'autre pièce : ignorée')
  -- électriques sans boîte indiquée : automatiques
  local function cls(cfg) return veh.classify(cfg, {Type = 'Car'}) end
  local ev = cls({model_key = 'vivace', key = 'e', pcFilename = '/v/e.pc', Transmission = 'Other', Propulsion = 'Electric'})
  local evM = cls({model_key = 'vivace', key = 'em', pcFilename = '/v/em.pc', Transmission = 'Manual', Propulsion = 'Electric'})
  local ice = cls({model_key = 'vivace', key = 'i', pcFilename = '/v/i.pc', Transmission = 'Other', Propulsion = 'ICE'})
  check(ev and ev.trans == 'auto', 'électrique "Other" : automatique', ev and ev.trans)
  check(evM and evM.trans == 'manual', 'électrique avec boîte indiquée : on garde la boîte', evM and evM.trans)
  check(ice and ice.trans == nil, 'thermique "Other" : inconnue', ice and ice.trans)
end

print('-- performance (grande grille)')
local bigNodes = citygen.city(110, 90)
local t0 = os.clock()
local gb = graph.build(bigNodes)
local t1 = os.clock()
local rb = loc.buildRoadSpots(gb)
local hb = loc.buildDeadEnds(gb)
local t2 = os.clock()
local cb = {}
for _, l in ipairs({rb, hb}) do for _, c in ipairs(l) do cb[#cb + 1] = c end end
local times = {}
for i = 1, 5 do
  local c = {}
  for k, v in pairs(base) do c[k] = v end
  c.g, c.cands, c.minD, c.maxD = gb, cb, 1000, 5000
  local s = os.clock()
  local r = loc.pickMission(c)
  times[#times + 1] = (os.clock() - s) * 1000
  check(r ~= nil, 'big map mission')
end
print(string.format('  %d noeuds, %d segments, %d candidats | graphe %.0f ms, lieux %.0f ms, mission %.0f/%.0f/%.0f ms',
  gb.n, gb.ne, #cb, (t1 - t0) * 1000, (t2 - t1) * 1000, times[1], times[2], times[3]))

print(string.format('PURE TESTS: %d passed, %d failed', passed, failed))
assert(failed == 0, 'tests failed')
