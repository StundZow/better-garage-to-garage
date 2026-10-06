local files = {
  '/lua/ge/extensions/livraisonLibre.lua',
  '/lua/ge/extensions/livraisonLibre/graph.lua',
  '/lua/ge/extensions/livraisonLibre/locations.lua',
  '/lua/ge/extensions/livraisonLibre/vehicles.lua',
  '/lua/ge/extensions/livraisonLibre/trafficCtl.lua',
  '/lua/ge/extensions/livraisonLibre/journal.lua',
  '/lua/ge/extensions/livraisonLibre/timing.lua',
  '/scripts/livraisonLibre/modScript.lua',
}
local bad = 0
for _, f in ipairs(files) do
  local fn, err = loadfile(MOD_ROOT .. f)
  if fn then print('OK  ', f) else print('FAIL', f, err); bad = bad + 1 end
end
-- détecte les globales accidentelles (affectations sans local) dans les modules purs
local function checkGlobals(path)
  local env = setmetatable({}, {__index = _G, __newindex = function(t, k, v) error('global write: ' .. tostring(k), 2) end})
  local fn = assert(loadfile(MOD_ROOT .. path))
  setfenv(fn, env)
  local ok, err = pcall(fn)
  print(ok and 'OK   no global writes' or ('FAIL ' .. tostring(err)), path)
  if not ok then bad = bad + 1 end
end
package.loaded['/lua/ge/extensions/livraisonLibre/graph'] = nil
checkGlobals('/lua/ge/extensions/livraisonLibre/graph.lua')
checkGlobals('/lua/ge/extensions/livraisonLibre/vehicles.lua')
checkGlobals('/lua/ge/extensions/livraisonLibre/timing.lua')
assert(bad == 0, bad .. ' fichier(s) en erreur')
print('syntax: all good')
