-- Livraison Libre - journal de toutes les livraisons (export CSV lisible dans Excel / LibreOffice)
-- Module "pur" : construit les lignes et le texte CSV, l'écriture des fichiers est faite par l'appelant.

-- Perfs : le trajet est chronométré de la 1re accélération jusqu'à 50 m de la zone ;
-- le stationnement (derniers 50 m) est mesuré à part.

local M = {}

-- ordre et titres des colonnes du CSV
M.COLUMNS = {
  {'id', 'N°'},
  {'date', 'Date'},
  {'heure', 'Heure'},
  {'map', 'Map'},
  {'result', 'Résultat'},
  {'reason', 'Motif'},
  {'vehicle', 'Véhicule'},
  {'brand', 'Marque'},
  {'model', 'Modèle'},
  {'config', 'Config'},
  {'category', 'Catégorie'},
  {'years', 'Années'},
  {'source', 'Provenance'},
  {'vehiclesUsed', 'Véhicules utilisés'},
  {'switches', 'Changements de véhicule'},
  {'fromKind', 'Départ (type)'},
  {'fromName', 'Départ'},
  {'toKind', 'Arrivée (type)'},
  {'toName', 'Arrivée'},
  {'plannedKm', 'Distance prévue (km)'},
  {'tripKm', 'Distance chronométrée (km)'},
  {'drivenKm', 'Distance parcourue totale (km)'},
  {'timeS', 'Temps de trajet (s)'},
  {'timeText', 'Temps de trajet'},
  {'avgKmh', 'Vitesse moyenne (km/h)'},
  {'vmaxKmh', 'Vitesse max (km/h)'},
  {'parkTimeS', 'Temps de stationnement (s)'},
  {'startDelayS', 'Attente avant départ (s)'},
  {'totalTimeS', 'Temps total (s)'},
  {'resets', 'Resets (R / Inser)'},
  {'damage', 'Dégâts'},
  {'traffic', 'Trafic'},
  {'trafficCount', 'Véhicules de trafic'},
  {'parkedCount', 'Voitures garées'},
  {'police', 'Police'},
  {'pursuits', 'Poursuites'},
  {'arrests', 'Arrestations'},
  {'maxStars', 'Étoiles max'},
  {'pursuitTimeS', 'Temps en poursuite (s)'},
  {'timeLimitS', 'Temps limite (s)'},
  {'locMode', 'Mode des lieux'},
  {'surface', 'Route'},
  {'validation', 'Validation'},
  {'zoneScale', 'Taille de zone'},
}

local function fmtTime(s)
  s = math.max(0, math.floor((s or 0) + 0.5))
  local h, m, sec = math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60
  if h > 0 then return string.format('%d:%02d:%02d', h, m, sec) end
  return string.format('%d:%02d', m, sec)
end
M.fmtTime = fmtTime

local function round(v, d)
  if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return nil end
  local p = 10 ^ (d or 0)
  return math.floor(v * p + 0.5) / p
end
M.round = round

-- Construit une ligne de journal à partir des données de mission (valeurs déjà calculées).
function M.makeRecord(d)
  local time = d.tripTime or 0
  local planned = d.plannedDist or 0
  local driven = d.drivenDist or 0
  local trip = d.tripDist or 0
  local rec = {
    id = d.id,
    date = d.date, heure = d.heure,
    map = d.map or '',
    result = d.result or '',
    reason = d.reason or '',
    vehicle = d.vehicle or '',
    brand = d.brand or '',
    model = d.model or '',
    config = d.config or '',
    category = d.category or '',
    years = d.years or '',
    source = d.source or '',
    switches = d.switches or 0,
    fromKind = d.fromKind or '', fromName = d.fromName or '',
    toKind = d.toKind or '', toName = d.toName or '',
    plannedKm = round(planned / 1000, 2),
    tripKm = round(trip / 1000, 2),
    drivenKm = round(driven / 1000, 2),
    timeS = round(time, 0),
    timeText = fmtTime(time),
    avgKmh = time >= 1 and round(trip / time * 3.6, 1) or 0,
    vmaxKmh = round((d.vmax or 0) * 3.6, 1),
    parkTimeS = d.parkTime and round(d.parkTime, 0) or '',
    startDelayS = d.startDelay and round(d.startDelay, 0) or '',
    totalTimeS = round(d.totalTime or 0, 0),
    resets = d.resets or 0,
    damage = round(d.damage or 0, 0),
    traffic = d.traffic and 'Oui' or 'Non',
    trafficCount = d.trafficCount or 0,
    parkedCount = d.parkedCount or 0,
    police = d.police or 'Aucune',
    pursuits = d.pursuits or 0,
    arrests = d.arrests or 0,
    maxStars = d.maxStars or 0,
    pursuitTimeS = round(d.pursuitTime or 0, 0),
    timeLimitS = d.timeLimit and round(d.timeLimit, 0) or '',
    locMode = d.locMode or '',
    surface = d.surface or '',
    validation = d.validation or '',
    zoneScale = round(d.zoneScale or 0, 2),
  }
  -- véhicules utilisés : "Nom (2,3 km) | Nom 2 (4,1 km)"
  local parts = {}
  for _, u in ipairs(d.used or {}) do
    local km = (string.format('%.1f', (u.dist or 0) / 1000):gsub('%.', ','))
    parts[#parts + 1] = string.format('%s (%s km)', u.name or '?', km)
  end
  rec.vehiclesUsed = table.concat(parts, ' | ')
  return rec
end

local function csvCell(v)
  if v == nil then return '' end
  local s
  if type(v) == 'number' then
    if v == math.floor(v) then s = string.format('%d', v) else s = (tostring(v):gsub('%.', ',')) end
  elseif type(v) == 'boolean' then
    s = v and 'Oui' or 'Non'
  else
    s = tostring(v)
  end
  if s:find('[;"\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
  return s
end

-- Texte CSV complet (UTF-8 avec BOM, séparateur ";" pour Excel en français)
function M.toCsv(records)
  local lines = {}
  local head = {}
  for i, c in ipairs(M.COLUMNS) do head[i] = csvCell(c[2]) end
  lines[1] = table.concat(head, ';')
  for _, r in ipairs(records or {}) do
    local row = {}
    for i, c in ipairs(M.COLUMNS) do row[i] = csvCell(r[c[1]]) end
    lines[#lines + 1] = table.concat(row, ';')
  end
  return '\239\187\191' .. table.concat(lines, '\r\n') .. '\r\n'
end

return M
