-- Génère un navgraph synthétique au format de map.getMap().nodes (liens d'un seul côté, comme BeamNG)
local M = {}

local function P(x, y, z) return {x = x, y = y, z = z or 0} end

function M.city(N, spacing, opts)
  opts = opts or {}
  N = N or 8
  spacing = spacing or 120
  local nodes = {}
  local function node(id, x, y, r)
    nodes[id] = {pos = P(x, y, opts.z or 10), radius = r or 4, links = {}, normal = P(0, 0, 1)}
    return id
  end
  local function link(a, b, data)
    data = data or {}
    data.drivability = data.drivability or 1
    data.inNode = data.inNode or a
    data.outNode = (data.inNode == a) and b or a
    -- convertToSingleSided : le lien est gardé sur le noeud "out", indexé par le noeud "in"
    nodes[data.outNode].links[data.inNode] = data
  end
  for i = 0, N - 1 do
    for j = 0, N - 1 do
      node('g' .. i .. '_' .. j, i * spacing, j * spacing, (j == 2) and 9 or 4)
    end
  end
  for i = 0, N - 1 do
    for j = 0, N - 1 do
      local a = 'g' .. i .. '_' .. j
      if i < N - 1 then
        local d = {}
        if i >= N - 3 then d.drivability = 0.3 end         -- est : routes en terre
        if j == 2 then d.speedLimit = 30 end               -- voie rapide
        if j == 4 then d.oneWay = true end                 -- sens unique
        link(a, 'g' .. (i + 1) .. '_' .. j, d)
      end
      if j < N - 1 then
        local d = {}
        if i >= N - 2 then d.drivability = 0.3 end
        link(a, 'g' .. i .. '_' .. (j + 1), d)
      end
    end
  end
  -- allées privées (culs-de-sac)
  local drives = 0
  for i = 1, N - 2, 2 do
    for j = 1, N - 2, 3 do
      local a = 'g' .. i .. '_' .. j
      local id = 'drive' .. i .. '_' .. j
      node(id, i * spacing + 30, j * spacing + 25, 2)
      link(a, id, {type = 'private', drivability = 0.75})
      drives = drives + 1
    end
  end
  -- île isolée
  node('isl1', -5000, -5000, 4)
  node('isl2', -5000, -4800, 4)
  link('isl1', 'isl2', {})
  return nodes, drives
end

return M
