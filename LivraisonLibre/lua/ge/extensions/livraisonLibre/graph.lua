-- Livraison Libre - graphe routier
-- Construit un graphe non orienté à partir de map.getMap().nodes (liens stockés d'un seul côté
-- dans BeamNG), avec composantes connexes, index spatial des segments et Dijkstra borné.
-- Module "pur" : n'utilise que des nombres (x, y, z), testable hors du jeu.

local M = {}

local sqrt, floor, ceil, huge, min, max, abs = math.sqrt, math.floor, math.ceil, math.huge, math.min, math.max, math.abs

local function countLanes(lanes)
  if type(lanes) ~= 'string' then return 0 end
  local n = 0
  for _ in lanes:gmatch('[%+%-]') do n = n + 1 end
  return n
end

local function cellKey(cx, cy)
  return (cx + 1048576) * 2097152 + (cy + 1048576)
end

function M.build(mapNodes, opts)
  opts = opts or {}
  local g = {
    ids = {}, idx = {},
    x = {}, y = {}, z = {}, r = {},
    nx = {}, ny = {}, nz = {},
    adj = {}, deg = {}, edges = {},
    n = 0, ne = 0,
  }

  local n = 0
  for nid, node in pairs(mapNodes or {}) do
    local p = node.pos
    if p then
      n = n + 1
      g.ids[n] = nid
      g.idx[nid] = n
      g.x[n], g.y[n], g.z[n] = p.x, p.y, p.z
      g.r[n] = node.radius or 2
      local nrm = node.normal
      if nrm then
        g.nx[n], g.ny[n], g.nz[n] = nrm.x, nrm.y, nrm.z
      else
        g.nx[n], g.ny[n], g.nz[n] = 0, 0, 1
      end
      g.adj[n] = {}
    end
  end
  g.n = n

  local seen = {}
  local ne = 0
  for nid, node in pairs(mapNodes or {}) do
    local i = g.idx[nid]
    if i and node.links then
      for lid, data in pairs(node.links) do
        local j = g.idx[lid]
        if j and j ~= i then
          local a, b = min(i, j), max(i, j)
          local key = a * (n + 1) + b
          if not seen[key] then
            seen[key] = true
            ne = ne + 1
            local dx, dy, dz = g.x[b] - g.x[a], g.y[b] - g.y[a], g.z[b] - g.z[a]
            local e = {
              a = a, b = b,
              len = sqrt(dx * dx + dy * dy + dz * dz),
              drv = tonumber(data.drivability) or 1,
              private = (data.type == 'private') or nil,
              oneWay = data.oneWay and true or nil,
              speed = tonumber(data.speedLimit),
              lanes = countLanes(data.lanes),
              inNode = data.inNode and g.idx[data.inNode] or nil,
            }
            g.edges[ne] = e
            local adjA, adjB = g.adj[a], g.adj[b]
            adjA[#adjA + 1] = ne
            adjB[#adjB + 1] = ne
          end
        end
      end
    end
  end
  g.ne = ne
  for i = 1, n do g.deg[i] = #g.adj[i] end

  M.buildComponents(g)
  M.buildGrid(g, opts.cellSize or 64)
  return g
end

-- Composantes connexes (BFS) + longueur totale de route par composante.
function M.buildComponents(g)
  local comp, compLen, compCount = {}, {}, 0
  local queue = {}
  for s = 1, g.n do
    if not comp[s] then
      compCount = compCount + 1
      local c = compCount
      comp[s] = c
      local len = 0
      local qh, qt = 1, 1
      queue[1] = s
      while qh <= qt do
        local u = queue[qh]; qh = qh + 1
        for _, ei in ipairs(g.adj[u]) do
          local e = g.edges[ei]
          local v = (e.a == u) and e.b or e.a
          if not comp[v] then
            comp[v] = c
            qt = qt + 1
            queue[qt] = v
          end
          if u == e.a then len = len + e.len end -- chaque arête comptée une fois
        end
      end
      compLen[c] = len
    end
  end
  g.comp, g.compLen, g.compCount = comp, compLen, compCount
  local best, bestLen = nil, -1
  for c = 1, compCount do
    if compLen[c] > bestLen then best, bestLen = c, compLen[c] end
  end
  g.mainComp, g.mainCompLen = best, max(bestLen, 0)
end

-- Index spatial : chaque segment est inséré dans les cellules qu'il traverse.
function M.buildGrid(g, cell)
  g.cell = cell
  local cells = {}
  for ei = 1, g.ne do
    local e = g.edges[ei]
    local ax, ay, bx, by = g.x[e.a], g.y[e.a], g.x[e.b], g.y[e.b]
    local steps = max(1, ceil(e.len / (cell * 0.5)))
    local last
    for k = 0, steps do
      local t = k / steps
      local cx, cy = floor((ax + (bx - ax) * t) / cell), floor((ay + (by - ay) * t) / cell)
      local key = cellKey(cx, cy)
      if key ~= last then
        local list = cells[key]
        if not list then list = {}; cells[key] = list end
        if list[#list] ~= ei then list[#list + 1] = ei end
        last = key
      end
    end
  end
  g.cells = cells
end

-- Point le plus proche sur un segment (2D) : renvoie t, distance², z interpolé.
local function closestOnEdge(g, e, px, py)
  local ax, ay, bx, by = g.x[e.a], g.y[e.a], g.x[e.b], g.y[e.b]
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = 0
  if l2 > 1e-9 then
    t = ((px - ax) * dx + (py - ay) * dy) / l2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local qx, qy = ax + dx * t, ay + dy * t
  local ex, ey = px - qx, py - qy
  return t, ex * ex + ey * ey, g.z[e.a] + (g.z[e.b] - g.z[e.a]) * t
end

-- Segment le plus proche d'un point. filter(e) optionnel. maxZ : écart vertical max (ponts).
function M.nearestEdge(g, px, py, pz, maxDist, filter, maxZ)
  maxDist = maxDist or 80
  maxZ = maxZ or 6
  local cell = g.cell
  local r = ceil(maxDist / cell)
  local cx, cy = floor(px / cell), floor(py / cell)
  local bestE, bestT, bestD2 = nil, 0, maxDist * maxDist
  local checked = {}
  for ix = cx - r, cx + r do
    for iy = cy - r, cy + r do
      local list = g.cells[cellKey(ix, iy)]
      if list then
        for _, ei in ipairs(list) do
          if not checked[ei] then
            checked[ei] = true
            local e = g.edges[ei]
            if not filter or filter(e) then
              local t, d2, z = closestOnEdge(g, e, px, py)
              if d2 < bestD2 and (not pz or abs(z - pz) <= maxZ) then
                bestE, bestT, bestD2 = ei, t, d2
              end
            end
          end
        end
      end
    end
  end
  if not bestE then return nil end
  return bestE, bestT, sqrt(bestD2)
end

-- Sources Dijkstra pour un point posé sur l'arête ei au paramètre t (+ distance d'accès off).
function M.sourcesFor(g, ei, t, off)
  local e = g.edges[ei]
  off = off or 0
  return {
    {node = e.a, d = t * e.len + off},
    {node = e.b, d = (1 - t) * e.len + off},
  }
end

-- Dijkstra borné (tas binaire). Renvoie dist[nodeIndex] pour les noeuds atteints <= maxDist.
function M.dijkstra(g, sources, maxDist)
  maxDist = maxDist or huge
  local dist = {}
  local hn, hd, hs = {}, {}, 0

  local function push(node, d)
    hs = hs + 1
    local i = hs
    while i > 1 do
      local p = floor(i / 2)
      if hd[p] <= d then break end
      hn[i], hd[i] = hn[p], hd[p]
      i = p
    end
    hn[i], hd[i] = node, d
  end

  local function pop()
    local node, d = hn[1], hd[1]
    local lastN, lastD = hn[hs], hd[hs]
    hn[hs], hd[hs] = nil, nil
    hs = hs - 1
    if hs > 0 then
      local i = 1
      while true do
        local l = i * 2
        if l > hs then break end
        local r = l + 1
        local c = (r <= hs and hd[r] < hd[l]) and r or l
        if hd[c] >= lastD then break end
        hn[i], hd[i] = hn[c], hd[c]
        i = c
      end
      hn[i], hd[i] = lastN, lastD
    end
    return node, d
  end

  for _, s in ipairs(sources) do
    if s.node and s.d <= maxDist and (dist[s.node] == nil or s.d < dist[s.node]) then
      dist[s.node] = s.d
      push(s.node, s.d)
    end
  end

  local adj, edges = g.adj, g.edges
  while hs > 0 do
    local u, du = pop()
    if du <= dist[u] then
      for _, ei in ipairs(adj[u]) do
        local e = edges[ei]
        local v = (e.a == u) and e.b or e.a
        local nd = du + e.len
        if nd <= maxDist then
          local dv = dist[v]
          if dv == nil or nd < dv then
            dist[v] = nd
            push(v, nd)
          end
        end
      end
    end
  end
  return dist
end

-- Distance routière d'un point attaché (ei, t, off) à partir d'une table dist.
function M.pointDist(g, dist, ei, t, off)
  local e = g.edges[ei]
  if not e then return nil end
  local da, db = dist[e.a], dist[e.b]
  local best
  if da then best = da + t * e.len end
  if db then
    local v = db + (1 - t) * e.len
    if not best or v < best then best = v end
  end
  if best then return best + (off or 0) end
  return nil
end

M.countLanes = countLanes
return M
