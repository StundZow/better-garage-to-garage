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
    -- vérification indépendante de la distance routière
    local dchk = graph.dijkstra(g, graph.sourcesFor(g, res.pickup.e, res.pickup.t, res.pickup.off))
    local real = loc.candDist(g, dchk, res.dest, res.pickup)
    check(real and approx(real, res.dist, 1e-6), 'reported dist matches dijkstra', tostring(real) .. ' vs ' .. res.dist)
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
local okRoad, nRoad, okSpot, nSpot = 0, 0, 0, 0
for run = 1, 300 do
  local ctx = {}
  for k, v in pairs(base) do ctx[k] = v end
  local res = loc.pickMission(ctx)
  if res and res.pickup.e then
    local p = res.pickup
    local e = g.edges[p.e]
    local fromDest = graph.dijkstra(g, graph.sourcesFor(g, res.dest.e, res.dest.t, res.dest.off))
    local viaA = fromDest[e.a] and (p.t * e.len + fromDest[e.a]) or math.huge
    local viaB = fromDest[e.b] and ((1 - p.t) * e.len + fromDest[e.b]) or math.huge
    local dx, dy = g.x[e.b] - g.x[e.a], g.y[e.b] - g.y[e.a]
    local z = res.pickupZone
    if p.kind == 'road' and not p.oneWay then
      nRoad = nRoad + 1
      local facesB = (z.fx * dx + z.fy * dy) > 0
      if (viaB <= viaA) == facesB then okRoad = okRoad + 1 end
      -- toujours garé du bon côté (à droite du sens de marche)
      local side = (z.x - p.x) * z.rx + (z.y - p.y) * z.ry
      check(side >= -1e-6, 'départ garé à droite dans son sens de marche', side)
    elseif p.kind ~= 'road' then
      nSpot = nSpot + 1
      local l = math.sqrt(dx * dx + dy * dy)
      local sgn = (viaB <= viaA) and 1 or -1
      local px = g.x[e.a] + dx * p.t + sgn * dx / l * 15
      local py = g.y[e.a] + dy * p.t + sgn * dy / l * 15
      if z.fx * (px - z.x) + z.fy * (py - z.y) >= 0 then okSpot = okSpot + 1 end
    end
  end
end
print(string.format('  route: %d/%d orientés vers le GPS, places/allées: %d/%d', okRoad, nRoad, okSpot, nSpot))
check(nRoad > 20 and okRoad == nRoad, 'départ sur route orienté vers la destination', okRoad .. '/' .. nRoad)
check(nSpot > 5 and okSpot == nSpot, 'départ sur place/allée : avant vers la route côté GPS', okSpot .. '/' .. nSpot)

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

print('-- trajet routier (graph.route)')
local gr = graph.build((citygen.city(9, 120)))
local spots = loc.buildRoadSpots(gr)
local okRoutes = 0
for i = 1, 30 do
  local a, b = spots[(i * 7) % #spots + 1], spots[(i * 13) % #spots + 1]
  local pts = graph.route(gr, a, b)
  if pts then
    local len = 0
    for k = 1, #pts - 1 do len = len + math.sqrt((pts[k + 1].x - pts[k].x) ^ 2 + (pts[k + 1].y - pts[k].y) ^ 2 + (pts[k + 1].z - pts[k].z) ^ 2) end
    local d = loc.candDist(gr, graph.dijkstra(gr, graph.sourcesFor(gr, a.e, a.t, 0)), b, a)
    local startOk = math.abs(pts[1].x - a.x) < 0.01 and math.abs(pts[1].y - a.y) < 0.01
    local endOk = math.abs(pts[#pts].x - b.x) < 0.01 and math.abs(pts[#pts].y - b.y) < 0.01
    if startOk and endOk and d and math.abs(len - d) < 1 then okRoutes = okRoutes + 1 end
  end
end
check(okRoutes == 30, 'trajet du départ à l arrivée, de la même longueur que la distance routière', okRoutes)

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
