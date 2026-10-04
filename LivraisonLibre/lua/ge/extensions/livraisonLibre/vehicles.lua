-- Livraison Libre - pool de véhicules
-- Classe chaque configuration (officielle ou mod) en catégories / époques / variantes / source,
-- exclut tout ce qui n'est pas un véhicule pilotable (props, remorques, trafic simplifié...)
-- et tire un véhicule au hasard selon les filtres du joueur. Module "pur".

local M = {}

M.CATEGORIES = {
  {id = 'citadine',    label = 'Citadines & compactes'},
  {id = 'berline',     label = 'Berlines'},
  {id = 'familiale',   label = 'Breaks & monospaces'},
  {id = 'coupe',       label = 'Coupés & cabriolets'},
  {id = 'sport',       label = 'Sportives'},
  {id = 'suv',         label = 'SUV & 4x4'},
  {id = 'pickup',      label = 'Pick-up'},
  {id = 'utilitaire',  label = 'Utilitaires'},
  {id = 'camion',      label = 'Camions'},
  {id = 'bus',         label = 'Bus'},
  {id = 'toutterrain', label = 'Buggy & tout-terrain'},
  {id = 'engin',       label = 'Engins de chantier'},
  {id = 'autre',       label = 'Autres'},
}

M.EPOCHS = {
  {id = 'ancienne', label = 'Anciennes (< 1980)',  lo = -math.huge, hi = 1979},
  {id = 'retro',    label = 'Années 80-90',         lo = 1980, hi = 1999},
  {id = 'moderne',  label = 'Modernes (2000+)',     lo = 2000, hi = math.huge},
  {id = 'inconnue', label = 'Année inconnue'},
}

M.VARIANTS = {
  {id = 'usine',   label = 'Série'},
  {id = 'custom',  label = 'Préparées / custom'},
  {id = 'course',  label = 'Course, rallye & drift'},
  {id = 'police',  label = 'Police'},
  {id = 'service', label = 'Services & secours'},
}

M.SOURCES = {
  {id = 'officiel', label = 'Officiels BeamNG'},
  {id = 'mod',      label = 'Mods'},
  {id = 'perso',    label = 'Mes configs'},
}

-- Types de véhicules autorisés (le reste = props, remorques, avions, bateaux...)
local ALLOWED_TYPES = {
  car = true, truck = true, ['heavy machinery'] = true, automation = true, unknown = true,
  motorcycle = true, motorbike = true, bike = true, bus = true, van = true, suv = true,
}

local EXCLUDED_MODELS = {
  unicycle = true, simple_traffic = true, testroller = true, roof_crush_tester = true,
  large_tire = true, flail = true, tsfb = true,
}

local BODY_MAP = {
  hatchback = 'citadine', compact = 'citadine', ['city car'] = 'citadine', subcompact = 'citadine',
  ['kei car'] = 'citadine', microcar = 'citadine', supermini = 'citadine',
  sedan = 'berline', liftback = 'berline', limousine = 'berline', saloon = 'berline', fastback = 'berline',
  notchback = 'berline',
  wagon = 'familiale', estate = 'familiale', ['shooting brake'] = 'familiale', minivan = 'familiale',
  mpv = 'familiale', ['station wagon'] = 'familiale',
  coupe = 'coupe', ['coupé'] = 'coupe', roadster = 'coupe', convertible = 'coupe', cabriolet = 'coupe',
  targa = 'coupe', speedster = 'coupe', ['sports car'] = 'coupe', supercar = 'coupe', hypercar = 'coupe',
  spider = 'coupe', spyder = 'coupe',
  suv = 'suv', crossover = 'suv', ['off-road'] = 'suv', offroad = 'suv', jeep = 'suv', cuv = 'suv',
  pickup = 'pickup', ['pickup truck'] = 'pickup', ute = 'pickup', ['pick-up'] = 'pickup',
  van = 'utilitaire', ['panel van'] = 'utilitaire', minibus = 'utilitaire', ambulance = 'utilitaire',
  ['cargo van'] = 'utilitaire', ['step van'] = 'utilitaire',
  ['fifth wheel truck'] = 'camion', semi = 'camion', ['semi truck'] = 'camion', ['tractor unit'] = 'camion',
  ['tanker truck'] = 'camion', ['dump truck'] = 'camion', ['mixer truck'] = 'camion',
  ['logging truck'] = 'camion', flatbed = 'camion', ['jato truck'] = 'camion', ['tow truck'] = 'camion',
  ['garbage truck'] = 'camion', ['fire truck'] = 'camion', truck = 'camion', lorry = 'camion',
  ['box truck'] = 'heavy?', ['chassis cab'] = 'heavy?',
  bus = 'bus', coach = 'bus', ['transit bus'] = 'bus', ['school bus'] = 'bus', ['city bus'] = 'bus',
  buggy = 'toutterrain', atv = 'toutterrain', utv = 'toutterrain', ['rock crawler'] = 'toutterrain',
  ['trophy truck'] = 'toutterrain', ['dune buggy'] = 'toutterrain', quad = 'toutterrain',
  ['wheel loader'] = 'engin', ['haul truck'] = 'engin', excavator = 'engin', tractor = 'engin',
  forklift = 'engin', bulldozer = 'engin', loader = 'engin',
  armored = 'utilitaire',
}

local function trim(s)
  if type(s) ~= 'string' then return nil end
  s = s:gsub('^%s+', ''):gsub('%s+$', '')
  if s == '' then return nil end
  return s
end

local function firstString(v)
  if type(v) == 'string' then return trim(v) end
  if type(v) == 'table' then
    for k, val in pairs(v) do
      if type(k) == 'string' and val == true then return trim(k) end
      if type(val) == 'string' then return trim(val) end
    end
  end
  return nil
end

local function yearsOf(v)
  if type(v) ~= 'table' then return nil end
  local lo, hi = tonumber(v.min), tonumber(v.max)
  if not lo and not hi then return nil end
  lo = lo or hi; hi = hi or lo
  if lo > hi then lo, hi = hi, lo end
  return lo, hi
end

local function isHeavy(cfg, model)
  local cc = firstString(cfg['Commercial Class']) or firstString(model and model['Commercial Class'])
  if cc then
    local cls = tonumber(cc:match('[Cc]lass%s*(%d+)'))
    if cls then return cls >= 6 end
    if cc:lower():find('bus') then return true end
  end
  local w = tonumber(cfg.Weight)
  return w ~= nil and w >= 5500
end

local function variantOf(cfg, body)
  local ct = (firstString(cfg['Config Type']) or ''):lower()
  if ct:find('police') then return 'police' end
  if ct:find('service') or ct:find('ambulance') or ct:find('fire') or ct:find('rescue') or ct:find('taxi') then return 'service' end
  if ct:find('race') or ct:find('rally') or ct:find('drag') or ct:find('drift') or ct:find('track') or ct:find('racing') then return 'course' end
  if ct:find('custom') or ct:find('tun') or ct:find('powerglow') or ct:find('modif') then return 'custom' end
  local b = (body or ''):lower()
  if b == 'ambulance' or b == 'armored' then return 'service' end
  return 'usine'
end

-- Renvoie une fiche normalisée, ou nil si ce n'est pas un véhicule pilotable.
function M.classify(cfg, model)
  if type(cfg) ~= 'table' then return nil end
  local key = cfg.model_key
  if not key or EXCLUDED_MODELS[key] then return nil end
  if not cfg.pcFilename and not cfg.key then return nil end
  if cfg.isAuxiliary or (model and model.isAuxiliary) then return nil end

  local typ = firstString(cfg.Type) or firstString(model and model.Type) or 'Unknown'
  if not ALLOWED_TYPES[typ:lower()] then return nil end
  local typL = typ:lower()

  local body = firstString(cfg['Body Style']) or firstString(model and model['Body Style'])
  local cats = {}
  local bodyL = body and body:lower()
  local mapped = bodyL and BODY_MAP[bodyL]
  if mapped == 'heavy?' then
    mapped = isHeavy(cfg, model) and 'camion' or 'utilitaire'
  end
  if typL == 'heavy machinery' then mapped = 'engin' end
  if not mapped then
    if typL == 'truck' then
      mapped = isHeavy(cfg, model) and 'camion' or 'utilitaire'
    elseif typL == 'bus' then
      mapped = 'bus'
    elseif typL == 'suv' then
      mapped = 'suv'
    elseif typL == 'van' then
      mapped = 'utilitaire'
    else
      mapped = 'autre'
    end
  end
  cats[mapped] = true

  local zero100 = tonumber(cfg['0-100 km/h'])
  local wp = tonumber(cfg['Weight/Power'])
  local top = tonumber(cfg['Top Speed'])
  local heavyCat = mapped == 'camion' or mapped == 'bus' or mapped == 'engin'
  if not heavyCat and ((zero100 and zero100 <= 6.0) or (wp and wp > 0 and wp <= 5.0) or (top and top >= 72)) then
    cats.sport = true
  end

  local ylo, yhi = yearsOf(cfg.Years)
  if not ylo then ylo, yhi = yearsOf(model and model.Years) end
  local epochs = {}
  if ylo then
    for _, ep in ipairs(M.EPOCHS) do
      if ep.lo and ylo <= ep.hi and yhi >= ep.lo then epochs[ep.id] = true end
    end
  else
    epochs.inconnue = true
  end

  local src = cfg.Source or (model and model.Source) or 'Mod'
  local srcKind = 'mod'
  if src == 'BeamNG - Official' then srcKind = 'officiel' elseif src == 'Custom' then srcKind = 'perso' end

  local w, l
  local bb = cfg.BoundingBox
  if type(bb) == 'table' and type(bb[1]) == 'table' and type(bb[2]) == 'table' then
    local x1, y1, x2, y2 = tonumber(bb[1][1]), tonumber(bb[1][2]), tonumber(bb[2][1]), tonumber(bb[2][2])
    if x1 and y1 and x2 and y2 then
      w, l = math.abs(x2 - x1), math.abs(y2 - y1)
      if w > l then w, l = l, w end
    end
  end
  if not w or w < 0.5 or l < 1 then
    local est = {camion = {2.6, 9.5}, bus = {2.6, 12}, engin = {3, 8}, utilitaire = {2.1, 5.6}, pickup = {2.1, 5.6}, suv = {2.0, 5.0}}
    local e = est[mapped] or {1.95, 4.8}
    w, l = e[1], e[2]
  end

  local yearsText
  if ylo then yearsText = (ylo == yhi) and tostring(ylo) or (tostring(ylo) .. '-' .. tostring(yhi)) end

  return {
    model = key,
    config = cfg.key,
    pc = cfg.pcFilename,
    name = cfg.Name or (model and model.Name) or key,
    modelName = (model and model.Name) or key,
    brand = firstString(cfg.Brand) or firstString(model and model.Brand) or '',
    preview = cfg.preview,
    source = src,
    srcKind = srcKind,
    body = body,
    cats = cats,
    mainCat = mapped,
    epochs = epochs,
    variant = variantOf(cfg, body),
    ylo = ylo, yhi = yhi, yearsText = yearsText,
    w = w, l = l,
    value = tonumber(cfg.Value),
  }
end

local function anyIn(set, wanted)
  for k in pairs(set) do
    if wanted[k] then return true end
  end
  return false
end

function M.isEligible(info, vs)
  if vs.blacklist and vs.blacklist[info.model] then return false end
  if vs.sources and not vs.sources[info.srcKind] then return false end
  if vs.variants and not vs.variants[info.variant] then return false end
  if vs.epochs and not anyIn(info.epochs, vs.epochs) then return false end
  if vs.cats and not anyIn(info.cats, vs.cats) then return false end
  return true
end

-- configs : liste de configs (core_vehicles.getConfigList(true).configs), getModel(key) -> table modèle
function M.buildPool(configs, getModel)
  local pool = {byModel = {}, models = {}, count = 0}
  for _, cfg in ipairs(configs or {}) do
    local model = getModel and getModel(cfg.model_key) or nil
    local ok, info = pcall(M.classify, cfg, model)
    if ok and info then
      local m = pool.byModel[info.model]
      if not m then
        m = {key = info.model, name = info.modelName, brand = info.brand, source = info.source, srcKind = info.srcKind, configs = {}, preview = nil}
        pool.byModel[info.model] = m
        pool.models[#pool.models + 1] = m
      end
      m.configs[#m.configs + 1] = info
      if cfg.is_default_config or not m.preview then m.preview = info.preview end
      pool.count = pool.count + 1
    end
  end
  table.sort(pool.models, function(a, b)
    local ka, kb = ((a.brand or '') .. ' ' .. (a.name or '')):lower(), ((b.brand or '') .. ' ' .. (b.name or '')):lower()
    if ka == kb then return a.key < b.key end
    return ka < kb
  end)
  return pool
end

-- Modèles éligibles avec leurs configs éligibles.
function M.eligibleModels(pool, vs)
  local out, configCount = {}, 0
  for _, m in ipairs(pool.models) do
    local list
    for _, info in ipairs(m.configs) do
      if M.isEligible(info, vs) then
        list = list or {}
        list[#list + 1] = info
      end
    end
    if list then
      out[#out + 1] = {model = m, configs = list}
      configCount = configCount + #list
    end
  end
  return out, configCount
end

-- Tire un modèle au hasard (en évitant les derniers utilisés si possible) puis une config.
function M.pick(eligible, rng, recent)
  rng = rng or math.random
  if not eligible or #eligible == 0 then return nil end
  local candidates = eligible
  if recent and #recent > 0 and #eligible > #recent then
    local recentSet = {}
    for _, k in ipairs(recent) do recentSet[k] = true end
    local filtered = {}
    for _, e in ipairs(eligible) do
      if not recentSet[e.model.key] then filtered[#filtered + 1] = e end
    end
    if #filtered > 0 then candidates = filtered end
  end
  local entry = candidates[rng(#candidates)]
  return entry.configs[rng(#entry.configs)]
end

-- Liste compacte pour l'interface (liste noire).
function M.modelSummaries(pool, vs)
  local out = {}
  for _, m in ipairs(pool.models) do
    local eligibleCount = 0
    local cats = {}
    for _, info in ipairs(m.configs) do
      local vsNoBlacklist = {sources = vs.sources, variants = vs.variants, epochs = vs.epochs, cats = vs.cats}
      if M.isEligible(info, vsNoBlacklist) then eligibleCount = eligibleCount + 1 end
      cats[info.mainCat] = true
    end
    local catList = {}
    for k in pairs(cats) do catList[#catList + 1] = k end
    table.sort(catList)
    out[#out + 1] = {
      key = m.key, name = m.name, brand = m.brand, source = m.source, srcKind = m.srcKind,
      preview = m.preview, configs = #m.configs, eligible = eligibleCount,
      banned = (vs.blacklist and vs.blacklist[m.key]) and true or false,
      cats = catList,
    }
  end
  return out
end

return M
