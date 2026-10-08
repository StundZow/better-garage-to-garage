-- Livraison Libre - lieux de livraison
-- Génère les emplacements candidats (bord de route, parkings, lieux d'intérêt, maisons, points perso),
-- calcule la zone de livraison adaptée à la taille du véhicule et choisit un couple départ/arrivée
-- en respectant la distance routière demandée. Module "pur" (nombres uniquement).

local graph = require('/lua/ge/extensions/livraisonLibre/graph')

local M = {}

local sqrt, floor, min, max, abs = math.sqrt, math.floor, math.min, math.max, math.abs

M.KINDS = {'road', 'parking', 'poi', 'home'}

local function norm3(x, y, z)
  local l = sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return 0, 1, 0 end
  return x / l, y / l, z / l
end

local function cross(ax, ay, az, bx, by, bz)
  return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

local function isHighway(g, e)
  if e.speed and e.speed >= 25 then return true end
  return ((g.r[e.a] + g.r[e.b]) * 0.5) >= 8.5
end

-- Emplacements en bord de route, échantillonnés le long des segments droits (hors routes privées).
function M.buildRoadSpots(g, opts)
  opts = opts or {}
  local spacing = opts.spacing or 45
  local endMargin = opts.endMargin or 8
  local junctionMargin = opts.junctionMargin or 18
  local minEdgeLen = opts.minEdgeLen or 20
  local minUpZ = opts.minUpZ or 0.94
  local step = graph.ticker(opts.tick)
  local out = {}
  for ei = 1, g.ne do
    step()
    local e = g.edges[ei]
    if not e.private and e.len >= minEdgeLen then
      local a, b = e.a, e.b
      local fx, fy, fz = norm3(g.x[b] - g.x[a], g.y[b] - g.y[a], g.z[b] - g.z[a])
      local count = max(1, floor(e.len / spacing))
      local fwdSign = 1
      if e.oneWay and e.inNode == b then fwdSign = -1 end
      local hw = isHighway(g, e)
      for k = 1, count do
        local t = (k - 0.5) / count
        local da, db = t * e.len, (1 - t) * e.len
        if da >= endMargin and db >= endMargin
          and (g.deg[a] < 3 or da >= junctionMargin)
          and (g.deg[b] < 3 or db >= junctionMargin) then
          local ux, uy, uz = norm3(
            g.nx[a] + (g.nx[b] - g.nx[a]) * t,
            g.ny[a] + (g.ny[b] - g.ny[a]) * t,
            g.nz[a] + (g.nz[b] - g.nz[a]) * t)
          if uz >= minUpZ and abs(fz) <= 0.35 then
            out[#out + 1] = {
              id = 'r' .. ei .. '_' .. k, kind = 'road',
              x = g.x[a] + (g.x[b] - g.x[a]) * t,
              y = g.y[a] + (g.y[b] - g.y[a]) * t,
              z = g.z[a] + (g.z[b] - g.z[a]) * t,
              fx = fx, fy = fy, fz = fz, ux = ux, uy = uy, uz = uz,
              half = g.r[a] + (g.r[b] - g.r[a]) * t,
              e = ei, t = t, off = 0, drv = e.drv,
              oneWay = e.oneWay, fwdSign = fwdSign, highway = hw,
              comp = g.comp[a],
            }
          end
        end
      end
    end
  end
  return out
end

-- Profondeur d'une allée : longueur de la chaîne privée depuis le fond (noeud i, segment ei) en
-- passant par les noeuds de degré 2, jusqu'au carrefour, moins la demi-largeur de la rue à ce
-- carrefour (= distance du fond au trottoir). Au-delà de 60 m, la valeur exacte n'a plus d'intérêt.
local function driveDepth(g, i, ei)
  local e = g.edges[ei]
  local u = (e.a == i) and e.b or e.a
  local len, prevE = e.len, ei
  for _ = 1, 200 do
    if g.deg[u] ~= 2 or len >= 60 then break end
    local adj = g.adj[u]
    local nei = (adj[1] == prevE) and adj[2] or adj[1]
    local ne = g.edges[nei]
    if not ne.private then break end
    len = len + ne.len
    u = (ne.a == u) and ne.b or ne.a
    prevE = nei
  end
  return max(0, len - g.r[u])
end

-- Culs-de-sac de routes privées = allées de maisons / garages.
function M.buildDeadEnds(g, opts)
  opts = opts or {}
  local step = graph.ticker(opts.tick)
  local out = {}
  for i = 1, g.n do
    step()
    if g.deg[i] == 1 then
      local ei = g.adj[i][1]
      local e = g.edges[ei]
      if e.private and e.len >= (opts.minLen or 6) then
        local j = (e.a == i) and e.b or e.a
        local fx, fy, fz = norm3(g.x[i] - g.x[j], g.y[i] - g.y[j], g.z[i] - g.z[j])
        if abs(fz) <= 0.35 and g.nz[i] >= 0.9 then
          out[#out + 1] = {
            id = 'h' .. i, kind = 'home', deadEnd = true,
            x = g.x[i], y = g.y[i], z = g.z[i],
            fx = fx, fy = fy, fz = fz, ux = g.nx[i], uy = g.ny[i], uz = g.nz[i],
            half = g.r[i], edgeLen = e.len, depth = driveDepth(g, i, ei),
            e = ei, t = (e.a == i) and 0 or 1, off = 0, drv = e.drv,
            comp = g.comp[i],
          }
        end
      end
    end
  end
  return out
end

-- Rattache des emplacements de parking (sites du niveau) au graphe routier.
-- spots : {name, label, kind, x, y, z, fx, fy, fz, w, l}
function M.attachSpots(g, spots, opts)
  opts = opts or {}
  local step = graph.ticker(opts.tick)
  local out = {}
  local taken = {}
  for k, s in ipairs(spots or {}) do
    step()
    local hk = graph.finite(s.x) and graph.finite(s.y) and graph.finite(s.z)
      and (floor(s.x / 1.5) .. ':' .. floor(s.y / 1.5) .. ':' .. floor(s.z / 3)) or nil
    if hk and not taken[hk] then
      taken[hk] = true
      local ei, t, d = graph.nearestEdge(g, s.x, s.y, s.z, opts.maxAttach or 70, nil, 8)
      if ei then
        local fx, fy, fz = norm3(s.fx or 0, s.fy or 1, s.fz or 0)
        out[#out + 1] = {
          id = 's' .. k, kind = s.kind or 'parking', label = s.label, name = s.name,
          x = s.x, y = s.y, z = s.z,
          fx = fx, fy = fy, fz = fz, ux = 0, uy = 0, uz = 1,
          spotW = s.w or 2.5, spotL = s.l or 5.5,
          e = ei, t = t, off = d, drv = g.edges[ei].drv,
          comp = g.comp[g.edges[ei].a],
        }
      end
    end
  end
  return out
end

-- Points perso : {id, name, pos={x,y,z}, dir={x,y,z}}
function M.attachCustom(g, points)
  local out = {}
  for _, p in ipairs(points or {}) do
    if type(p) == 'table' and type(p.pos) == 'table' and graph.finite(p.pos.x) and graph.finite(p.pos.y) and graph.finite(p.pos.z) then
      local fx, fy, fz = norm3(p.dir and p.dir.x or 0, p.dir and p.dir.y or 1, p.dir and p.dir.z or 0)
      local c = {
        id = 'c' .. tostring(p.id), pointId = p.id, kind = 'custom', label = p.name,
        x = p.pos.x, y = p.pos.y, z = p.pos.z,
        fx = fx, fy = fy, fz = fz, ux = 0, uy = 0, uz = 1,
        drv = 1, off = 0,
      }
      if g then
        local ei, t, d = graph.nearestEdge(g, c.x, c.y, c.z, 150, nil, 12)
        if ei then
          c.e, c.t, c.off = ei, t, d
          c.comp = g.comp[g.edges[ei].a]
        end
      end
      out[#out + 1] = c
    end
  end
  return out
end

function M.fits(c, vehW, vehL, scale)
  local zw = vehW * scale
  if c.kind == 'road' then
    return c.half * 2 >= zw * 0.95
  elseif c.deadEnd then
    -- assez large, et assez profonde pour que la zone ne déborde pas sur la rue
    return c.half * 2 >= zw * 0.75 and (c.depth or c.edgeLen or 0) >= vehL * scale
  elseif c.kind == 'custom' then
    return true
  end
  return (c.spotW or 0) >= vehW * 0.98 and (c.spotL or 0) >= vehL * 0.9
end

-- Zone de livraison (centre, axes, taille) pour un candidat et un véhicule donnés.
-- legalSide : 1 = on roule à droite, -1 = à gauche. dirSign : sens choisi sur une route à double sens.
-- force : calcule la zone même si le véhicule est un peu trop grand pour l'emplacement.
function M.zoneFor(c, vehW, vehL, scale, legalSide, dirSign, force)
  if not force and not M.fits(c, vehW, vehL, scale) then return nil end
  local zw, zl = vehW * scale, vehL * scale
  local fx, fy, fz = c.fx, c.fy, c.fz
  local ux, uy, uz = c.ux or 0, c.uy or 0, c.uz or 1
  local x, y, z = c.x, c.y, c.z
  dirSign = dirSign or 1
  if c.kind == 'road' then
    local s = c.oneWay and (c.fwdSign or 1) or dirSign
    fx, fy, fz = fx * s, fy * s, fz * s
    local rx, ry, rz = norm3(cross(fx, fy, fz, ux, uy, uz))
    local off = max(0, c.half - zw * 0.5 - 0.15) * (legalSide or 1)
    x, y, z = x + rx * off, y + ry * off, z + rz * off
  elseif c.deadEnd then
    -- recule la zone dans l'allée : l'avant près du fond, l'arrière avant le trottoir
    local shift = zl * 0.5 + 0.5
    if c.depth and c.depth >= zl then
      shift = min(shift, c.depth - zl * 0.5)
    else
      shift = min(shift, (c.edgeLen or zl) * 0.85) -- allée trop courte (zone forcée)
    end
    x, y, z = x - fx * shift, y - fy * shift, z - fz * shift
  end
  local rx, ry, rz = norm3(cross(fx, fy, fz, ux, uy, uz))
  return {x = x, y = y, z = z, fx = fx, fy = fy, fz = fz, rx = rx, ry = ry, rz = rz, ux = ux, uy = uy, uz = uz, w = zw, l = zl, dirSign = dirSign}
end

-- Teste si un point (x, y, z) est dans le rectangle de la zone (z : tolérance verticale).
function M.pointInZone(zone, px, py, pz, zTol)
  local dx, dy, dz = px - zone.x, py - zone.y, pz - zone.z
  local along = dx * zone.fx + dy * zone.fy + dz * zone.fz
  local side = dx * zone.rx + dy * zone.ry + dz * zone.rz
  local up = dx * zone.ux + dy * zone.uy + dz * zone.uz
  return abs(along) <= zone.l * 0.5 and abs(side) <= zone.w * 0.5 and abs(up) <= (zTol or 4)
end

function M.eligible(c, f)
  if f.kinds and not f.kinds[c.kind] then return false end
  if f.paved and (c.drv or 1) < (f.pavedThreshold or 0.7) then return false end
  if f.avoidHighways and c.highway then return false end
  return true
end

local function randInt(rng, n) return rng(n) end

local function pickByKind(list, rng)
  local byKind, kinds = {}, {}
  for _, item in ipairs(list) do
    local k = item.c.kind
    if not byKind[k] then byKind[k] = {}; kinds[#kinds + 1] = k end
    local l = byKind[k]
    l[#l + 1] = item
  end
  if #kinds == 0 then return nil end
  table.sort(kinds)
  local l = byKind[kinds[randInt(rng, #kinds)]]
  return l[randInt(rng, #l)]
end

local function removeItem(list, item)
  for i = #list, 1, -1 do
    if list[i] == item then table.remove(list, i) return end
  end
end

-- Distance (routière si possible) depuis la table dist ; sinon distance à vol d'oiseau majorée.
-- dir = 1 : dist calculée dans le sens de circulation depuis from (nil : sens uniques ignorés).
local function candDist(g, dist, c, from, dir)
  if g and dist and c.e then
    local d = graph.pointDist(g, dist, c.e, c.t, c.off, dir)
    if from and from.e == c.e then
      -- même segment : trajet direct le long de la route (sauf à contresens d'un sens unique)
      local direct = graph.alongEdge(g, c.e, from.t or 0, c.t or 0, dir)
      if direct then
        direct = direct + (from.off or 0) + (c.off or 0)
        if not d or direct < d then d = direct end
      end
    end
    if d then return d end
  end
  if from and (not g or not c.e or not dist) then
    local dx, dy, dz = c.x - from.x, c.y - from.y, c.z - from.z
    return sqrt(dx * dx + dy * dy + dz * dz) * 1.25
  end
  return nil
end

local function sourcesOf(g, p, dir)
  if g and p.e then return graph.sourcesFor(g, p.e, p.t or 0, p.off or 0, dir) end
  return nil
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Choisit une destination depuis un point de départ (p : candidat ou {x,y,z,e,t,off}).
-- dir = 1 : distances dans le sens de circulation (celles du GPS) ; nil : sens uniques ignorés.
-- Renvoie inRange, others, trapped (départ coincé : ce qui est hors d'atteinte dans le bon sens est
-- mesuré sans les sens uniques).
local function chooseDest(ctx, pool, p, maxSearch, dir)
  local g = ctx.g
  local sources = sourcesOf(g, p, dir)
  local dist, capped, distU
  if sources then dist, capped = graph.dijkstra(g, sources, maxSearch, nil, dir) end
  if dir and dist and not capped then
    -- tout ce qu'on peut atteindre dans le bon sens a été vu : si c'est bien moins que sans les sens
    -- uniques, le départ est coincé par des sens uniques sans issue (données de la map). Le GPS en
    -- sortira à contresens : le reste est alors mesuré sans les sens uniques.
    local reach = countKeys(dist)
    local comp = g.comp and g.comp[g.edges[p.e].a]
    if not (comp and g.compNodes and reach * 2 >= g.compNodes[comp]) then -- sinon : pas coincé, inutile de vérifier
      distU = graph.dijkstra(g, sourcesOf(g, p), maxSearch)
      if reach * 2 >= countKeys(distU) then distU = nil end
    end
  end
  local inRange, others = {}, {}
  local minD, maxD = ctx.minD, ctx.maxD
  local minSep2 = (ctx.minSeparation or 40) ^ 2
  for _, c in ipairs(pool) do
    if c ~= p and not (ctx.exclude and ctx.exclude[c.id]) then
      local dx, dy = c.x - p.x, c.y - p.y
      if dx * dx + dy * dy >= minSep2 then
        local d, wrong = candDist(g, dist, c, p, dir), nil
        if not d and distU then d, wrong = candDist(g, distU, c, p), true end
        if d then
          if d >= minD and d <= maxD then
            inRange[#inRange + 1] = {c = c, d = d, wrong = wrong}
          else
            others[#others + 1] = {c = c, d = d, wrong = wrong}
          end
        end
      end
    end
  end
  return inRange, others, distU ~= nil
end

local function finalizeDest(ctx, list)
  local tries = 0
  while #list > 0 and tries < 40 do
    tries = tries + 1
    local item = pickByKind(list, ctx.rng)
    local dirSign = (ctx.rng(2) == 1) and 1 or -1
    local zone = M.zoneFor(item.c, ctx.vehW, ctx.vehL, ctx.scale, ctx.legalSide, dirSign)
    if zone and (not ctx.isFree or ctx.isFree(zone, item.c)) then
      return item, zone
    end
    removeItem(list, item)
  end
  return nil
end

-- Oriente la zone de départ (donc le véhicule au spawn) dans le sens du trajet GPS vers la destination.
-- Route à double sens : on choisit le sens qui mène à la destination (et le bon côté de la route).
-- Sens unique : sens légal conservé. Place / allée / point perso : l'avant vers la route, côté trajet.
function M.orientPickup(g, pickup, pZone, dest, ctx, maxSearch)
  if not g or not pickup or not pZone or not dest or not pickup.e or not dest.e then return pZone end
  if pickup.kind == 'road' and pickup.oneWay then return pZone end
  local e = g.edges[pickup.e]
  local pt, dt = pickup.t or 0, dest.t or 0
  -- trajet restant en partant vers a / vers b : recherche à rebours depuis la destination, dans le
  -- sens de circulation ; sans les sens uniques si rien n'est relié ainsi (données de la map)
  local viaA, viaB, da, db
  for pass = 1, 2 do
    local dir = (pass == 1) and -1 or nil
    local fromDest = graph.dijkstra(g, graph.sourcesFor(g, dest.e, dt, dest.off or 0, dir), maxSearch, nil, dir)
    da, db = fromDest[e.a], fromDest[e.b]
    viaA, viaB = graph.endDists(g, fromDest, pickup.e, pt, dir)
    if pickup.e == dest.e then
      -- même segment : tout droit vers la destination si c'est permis
      local direct = graph.alongEdge(g, pickup.e, pt, dt, dir)
      if direct then
        direct = direct + (dest.off or 0)
        if dt < pt then viaA = min(viaA or direct, direct) else viaB = min(viaB or direct, direct) end
      end
    end
    if viaA or viaB then break end
  end
  if not viaA and not viaB then
    -- pas de trajet (destination hors d'atteinte) : au fond d'une allée, on repart quand même vers la rue
    if not pickup.deadEnd then return pZone end
    if pt == 0 then viaB = 0 else viaA = 0 end
  end
  viaA, viaB = viaA or math.huge, viaB or math.huge
  local ax, ay, bx, by = g.x[e.a], g.y[e.a], g.x[e.b], g.y[e.b]
  local dirx, diry = bx - ax, by - ay
  -- égalité (fond d'allée : passer par a ou b revient au même) : vers le noeud le plus proche de l'arrivée
  if viaA < viaB - 1e-6 or (abs(viaA - viaB) <= 1e-6 and (da or math.huge) < (db or math.huge)) then
    dirx, diry = -dirx, -diry
  end
  local l = sqrt(dirx * dirx + diry * diry)
  if l < 1e-6 then return pZone end
  dirx, diry = dirx / l, diry / l

  if pickup.kind == 'road' then
    local s = ((pickup.fx * dirx + pickup.fy * diry) >= 0) and 1 or -1
    if s == pZone.dirSign then return pZone end
    local z = M.zoneFor(pickup, ctx.vehW, ctx.vehL, ctx.scale, ctx.legalSide, s, true)
    if ctx.isFree and not ctx.isFree(z, pickup) then return pZone end -- l'autre côté de la route est occupé
    return z
  end
  -- point de la route où commence le trajet, un peu dans le sens du GPS
  local px, py = ax + (bx - ax) * pt + dirx * 15, ay + (by - ay) * pt + diry * 15
  local tx, ty = px - pZone.x, py - pZone.y
  if pZone.fx * tx + pZone.fy * ty < 0 then
    local z = {}
    for k, v in pairs(pZone) do z[k] = v end
    z.fx, z.fy, z.fz = -pZone.fx, -pZone.fy, -pZone.fz
    z.rx, z.ry, z.rz = -pZone.rx, -pZone.ry, -pZone.rz
    z.flipped = true
    return z
  end
  return pZone
end

local function closestToRange(ctx, others)
  local best, bestScore
  local mid = (ctx.minD + ctx.maxD) * 0.5
  for _, item in ipairs(others) do
    local score
    if item.d < ctx.minD then score = ctx.minD - item.d
    elseif item.d > ctx.maxD then score = item.d - ctx.maxD
    else score = abs(item.d - mid) * 0.01 end
    if item.d >= 60 and (not bestScore or score < bestScore) then best, bestScore = item, score end
  end
  if not best then return {} end
  -- garde quelques candidats proches du meilleur score pour varier
  local out = {}
  for _, item in ipairs(others) do
    if item.d >= 60 and abs(item.d - best.d) <= max(150, best.d * 0.15) then out[#out + 1] = item end
  end
  return out
end

-- Aucune destination à la bonne distance : la plus proche de la fourchette demandée, dans le sens de
-- circulation, sinon sans les sens uniques (données de la map incohérentes).
local function relaxedDest(ctx, pool, p, searchMax)
  local wideMax = max(searchMax * 3, 5000)
  local _, wide = chooseDest(ctx, pool, p, wideMax, 1)
  local item, zone = finalizeDest(ctx, closestToRange(ctx, wide))
  if not item then
    _, wide = chooseDest(ctx, pool, p, wideMax)
    item, zone = finalizeDest(ctx, closestToRange(ctx, wide))
  end
  return item, zone
end

--[[
ctx = {
  g, cands, filter = {kinds, paved, pavedThreshold, avoidHighways},
  minD, maxD, vehW, vehL, scale, legalSide, rng = function(n) -> 1..n,
  from = {x,y,z,e,t,off} | nil  -> départ fixe (position actuelle)
  isFree = function(zone, cand) -> bool | nil
  exclude = {candId = true} | nil
  customMode = bool
}
renvoie res = {pickup, pickupZone, dest, destZone, dist, relaxed} ou nil, raison
]]
function M.pickMission(ctx)
  ctx.rng = ctx.rng or math.random
  local g = ctx.g
  local pool = {}
  for _, c in ipairs(ctx.cands or {}) do
    if (ctx.customMode or M.eligible(c, ctx.filter or {})) and M.fits(c, ctx.vehW, ctx.vehL, ctx.scale) then
      pool[#pool + 1] = c
    end
  end
  if ctx.customMode then
    local need = ctx.from and 1 or 2
    if #pool < need then return nil, 'need_points' end
  elseif #pool == 0 then
    return nil, 'no_candidates'
  end

  local searchMax = ctx.maxD * 1.05 + 50

  -- départ coincé : d'abord une destination atteignable dans le bon sens, s'il y en a
  local function finalizeLegalFirst(list)
    local legal = {}
    for _, it in ipairs(list) do if not it.wrong then legal[#legal + 1] = it end end
    if #legal > 0 and #legal < #list then
      local item, zone = finalizeDest(ctx, legal)
      if item then return item, zone end
    end
    return finalizeDest(ctx, list)
  end

  -- Départ fixe (position actuelle du joueur)
  if ctx.from then
    local inRange = chooseDest(ctx, pool, ctx.from, searchMax, 1)
    local item, zone = finalizeLegalFirst(inRange)
    local relaxed = false
    if not item then
      relaxed = true
      item, zone = relaxedDest(ctx, pool, ctx.from, searchMax)
    end
    if not item then return nil, 'no_destination' end
    return {dest = item.c, destZone = zone, dist = item.d, relaxed = relaxed}
  end

  -- Départ aléatoire : on privilégie les grandes composantes du réseau routier
  local pickPool = {}
  if ctx.customMode then
    pickPool = pool
  else
    local minCompLen = max(ctx.minD * 1.5, 800)
    for _, c in ipairs(pool) do
      local cl = c.comp and g.compLen[c.comp] or 0
      if cl >= minCompLen or c.comp == g.mainComp then pickPool[#pickPool + 1] = c end
    end
    if #pickPool == 0 then pickPool = pool end
  end

  local function mission(pickup, pZone, item, zone, relaxed)
    pZone = M.orientPickup(g, pickup, pZone, item.c, ctx, item.d * 1.5 + 500)
    return {pickup = pickup, pickupZone = pZone, dest = item.c, destZone = zone, dist = item.d, relaxed = relaxed}
  end

  local lastPickup, lastPickupZone, trapped
  for _ = 1, (ctx.maxTries or 12) do
    local wrapped = {}
    for i, c in ipairs(pickPool) do wrapped[i] = {c = c} end
    local pItem = pickByKind(wrapped, ctx.rng)
    if not pItem then break end
    local pickup = pItem.c
    local pZone = M.zoneFor(pickup, ctx.vehW, ctx.vehL, ctx.scale, ctx.legalSide, (ctx.rng(2) == 1) and 1 or -1)
    if pZone and (not ctx.isFree or ctx.isFree(pZone, pickup)) then
      local inRange, _, isTrapped = chooseDest(ctx, pool, pickup, searchMax, 1)
      if isTrapped then
        -- départ coincé par des sens uniques sans issue (le GPS partirait à contresens) : on en
        -- essaie un autre, celui-ci reste en dernier recours
        trapped = trapped or {pickup = pickup, zone = pZone, inRange = inRange}
      else
        local item, zone = finalizeDest(ctx, inRange)
        if item then return mission(pickup, pZone, item, zone, false) end
        lastPickup, lastPickupZone = pickup, pZone
      end
    end
  end

  if trapped then
    local item, zone = finalizeLegalFirst(trapped.inRange)
    if item then return mission(trapped.pickup, trapped.zone, item, zone, false) end
    if not lastPickup then lastPickup, lastPickupZone = trapped.pickup, trapped.zone end
  end
  if lastPickup then
    local item, zone = relaxedDest(ctx, pool, lastPickup, searchMax)
    if item then return mission(lastPickup, lastPickupZone, item, zone, true) end
  end
  return nil, 'no_destination'
end

M.candDist = candDist

-- Emplacement compatible le plus proche d'un point (utilisé quand on change de véhicule en route)
function M.nearestFitting(cands, x, y, vehW, vehL, scale, filter, maxRadius, isFree, legalSide)
  local best, bestD2, bestZone
  local r2 = (maxRadius or 600) ^ 2
  local list = {}
  for _, c in ipairs(cands or {}) do
    local dx, dy = c.x - x, c.y - y
    local d2 = dx * dx + dy * dy
    if d2 <= r2 and (not filter or M.eligible(c, filter)) and M.fits(c, vehW, vehL, scale) then
      list[#list + 1] = {c = c, d2 = d2}
    end
  end
  table.sort(list, function(a, b) return a.d2 < b.d2 end)
  for i = 1, math.min(#list, 25) do
    local zone = M.zoneFor(list[i].c, vehW, vehL, scale, legalSide, 1)
    if zone and (not isFree or isFree(zone, list[i].c)) then
      best, bestD2, bestZone = list[i].c, list[i].d2, zone
      break
    end
  end
  return best, bestZone, bestD2 and sqrt(bestD2) or nil
end

function M.countByKind(cands)
  local out = {road = 0, parking = 0, poi = 0, home = 0}
  for _, c in ipairs(cands or {}) do
    out[c.kind] = (out[c.kind] or 0) + 1
  end
  return out
end

return M
