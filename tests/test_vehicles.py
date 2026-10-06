import os, re, json, glob, zipfile, collections, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from run import new_runtime

# Classification sur les vrais véhicules installés (lecture seule).
#   BEAMNG_DIR       : dossier d'installation du jeu (contient content/vehicles)
#   BEAMNG_USER_DIR  : dossier utilisateur (contient mods) - optionnel
GAME = os.path.join(os.environ.get('BEAMNG_DIR', ''), 'content', 'vehicles').replace(os.sep, '/')
MODS = os.path.join(os.environ.get('BEAMNG_USER_DIR', ''), 'mods').replace(os.sep, '/')
if not os.environ.get('BEAMNG_DIR') or not os.path.isdir(GAME):
    print('BEAMNG_DIR non défini : test ignoré (ex. BEAMNG_DIR="C:/.../BeamNG.drive")')
    sys.exit(0)

def lj(b):
    s = b.decode('utf-8', 'ignore')
    s = re.sub(r'(?m)^\s*//.*$', '', s)
    s = re.sub(r',\s*([}\]])', r'\1', s)
    try:
        return json.loads(s)
    except Exception:
        return None

PC_SOURCES = {}  # '/vehicles/<model>/<config>.pc' -> (zip, nom interne)


def scan_zip(path, source):
    out_models, out_configs = {}, []
    try:
        zf = zipfile.ZipFile(path)
    except Exception:
        return out_models, out_configs
    names = zf.namelist()
    by_model = collections.defaultdict(lambda: {'info': None, 'pcs': [], 'infos': {}})
    for n in names:
        p = n.split('/')
        if len(p) == 3 and p[0] == 'vehicles':
            m, f = p[1], p[2]
            if f == 'info.json':
                by_model[m]['info'] = n
            elif f.endswith('.pc'):
                by_model[m]['pcs'].append(f[:-3])
            elif f.startswith('info_') and f.endswith('.json'):
                by_model[m]['infos'][f[5:-5]] = n
    for m, d in by_model.items():
        if not d['pcs'] and not d['info']:
            continue
        info = lj(zf.read(d['info'])) if d['info'] else None
        if info is None:
            info = {'Name': m, 'Type': 'Car'}
        model = dict(info)
        model.setdefault('Type', 'Unknown')
        model['key'] = m
        out_models[m] = model
        for k in d['pcs']:
            cfg = {}
            if k in d['infos']:
                cfg = lj(zf.read(d['infos'][k])) or {}
            cfg = dict(cfg)
            cfg['model_key'] = m
            cfg['key'] = k
            cfg['pcFilename'] = '/vehicles/%s/%s.pc' % (m, k)
            PC_SOURCES[cfg['pcFilename']] = (path, 'vehicles/%s/%s.pc' % (m, k))
            cfg['Configuration'] = cfg.get('Configuration', k)
            cfg['Name'] = '%s %s' % (model.get('Name', m), cfg['Configuration'])
            cfg['Source'] = source
            cfg['preview'] = '/vehicles/%s/%s.jpg' % (m, k)
            if cfg.get('isAuxiliary') is None and model.get('isAuxiliary') is not None:
                cfg['isAuxiliary'] = model['isAuxiliary']
            out_configs.append(cfg)
    return out_models, out_configs

t0 = time.time()
models, configs = {}, []
for z in sorted(glob.glob(GAME + '/*.zip')):
    m, c = scan_zip(z, 'BeamNG - Official')
    models.update(m); configs += c
n_off = len(configs)
for z in sorted(glob.glob(MODS + '/*.zip')):
    m, c = scan_zip(z, os.path.basename(z)[:-4])
    # un mod qui remplace un modèle officiel garde la même clé : on garde le dernier
    models.update(m); configs += c
print('scan: %d modèles, %d configs (%d officielles) en %.1fs' % (len(models), len(configs), n_off, time.time() - t0))

L = new_runtime()
vehLib = L.eval("require('/lua/ge/extensions/livraisonLibre/vehicles')")
lua_configs = L.table_from(configs, recursive=True)
lua_models = L.table_from(models, recursive=True)
getModel = L.eval('function(models) return function(k) return models[k] end end')(lua_models)
t1 = time.time()
def read_pc(pc_path):
    src = PC_SOURCES.get(pc_path)
    if not src:
        return None
    d = lj(zipfile.ZipFile(src[0]).read(src[1]))
    return L.table_from(d, recursive=True) if isinstance(d, dict) else None


pool = vehLib.buildPool(lua_configs, getModel, read_pc)
print('buildPool: %.0f ms' % ((time.time() - t1) * 1000))

nmodels = len(pool.models)
print('pilotables: %d modèles, %d configs (%d .pc lus pour deviner la boîte)' % (nmodels, pool.count, pool.pcReads))

cats = collections.Counter(); epochs = collections.Counter(); variants = collections.Counter(); srcs = collections.Counter(); trans = collections.Counter()
problems = []
excluded_keys = set(models.keys())
for i in range(1, nmodels + 1):
    m = pool.models[i]
    excluded_keys.discard(m.key)
    for j in range(1, len(m.configs) + 1):
        info = m.configs[j]
        for k in info.cats: cats[k] += 1
        for k in info.epochs: epochs[k] += 1
        variants[info.variant] += 1
        srcs[info.srcKind] += 1
        trans[info.trans or 'inconnue'] += 1
        mt = models[m.key].get('Type')
for k, v in cats.most_common(): print('  cat %-12s %d' % (k, v))
print('  epochs', dict(epochs)); print('  variants', dict(variants)); print('  sources', dict(srcs)); print('  boîtes', dict(trans))
assert trans['auto'] > 100 and trans['manual'] > 100, trans
def trans_of(model, config):
    m = pool.byModel[model]
    if not m: return None
    for j in range(1, len(m.configs) + 1):
        if m.configs[j].config == config: return m.configs[j].trans
    return 'absent'
for model, config, want in [('etk800', '846x_ttsport_plus_DCT', 'auto'), ('barstow', '291a', 'auto'), ('autobello', '110a_m', 'manual')]:
    got = trans_of(model, config)
    print('  boîte %s/%s = %s' % (model, config, got))
    assert got in (want, 'absent', None) and (got == want or got == 'absent'), (model, config, got)
# filtre
vsT = L.eval("{transmission = 'manual'}")
elM, cM = vehLib.eligibleModels(pool, vsT)
vsT.transmission = 'auto'
elA, cA = vehLib.eligibleModels(pool, vsT)
print('  filtre boîte : %d configs manuelles, %d automatiques' % (cM, cA))
assert cM == trans['manual'] and cA == trans['auto']

# aucun prop / remorque / trafic simplifié ne doit passer
bad_types = {'prop', 'trailer', 'proptraffic', 'propparked', 'traffic'}
leaks = []
for c in configs:
    t = (c.get('Type') or models[c['model_key']].get('Type') or '').strip().lower()
    if t in bad_types:
        k = c['model_key']
        m = pool.byModel[k]
        if m:
            for j in range(1, len(m.configs) + 1):
                if m.configs[j].config == c['key']:
                    leaks.append((k, c['key'], t))
print('fuites props/remorques/trafic:', len(leaks), leaks[:5])
assert not leaks

print('modèles exclus (échantillon):', sorted(excluded_keys)[:40])
for must in ['pickup', 'etk800', 'vivace', 'us_semi', 'citybus', 'covet', 'bastion']:
    assert pool.byModel[must], must + ' manquant'
for mustNot in ['cones', 'flatbed', 'dryvan', 'ball', 'simple_traffic', 'unicycle', 'caravan']:
    assert not pool.byModel[mustNot], mustNot + ' ne devrait pas être pilotable'

def show(key):
    m = pool.byModel[key]
    if not m: print('  (absent)', key); return
    c = m.configs[1]
    print('  %-14s %-40s cats=%s epochs=%s variant=%s src=%s size=%.2fx%.2f years=%s' % (
        key, str(c.name)[:40], sorted(list(c.cats)), sorted(list(c.epochs)), c.variant, c.srcKind, c.w, c.l, c.yearsText))
for k in ['pickup', 'us_semi', 'citybus', 'scintilla', 'covet', 'atv', 'dumptruck', 'van', 'roamer', 'md_series', 'miramar', 'bolide']:
    show(k)

# filtres par défaut du mod
vs = L.eval('''{
  cats = {citadine=true, berline=true, familiale=true, coupe=true, sport=true, suv=true, pickup=true, utilitaire=true, camion=false, bus=false, toutterrain=false, engin=false, autre=true},
  epochs = {ancienne=true, retro=true, moderne=true, inconnue=true},
  variants = {usine=true, custom=true, course=false, police=false, service=false},
  sources = {officiel=true, mod=true, perso=false},
  blacklist = {},
}''')
el, cfgCount = vehLib.eligibleModels(pool, vs)
print('filtres par défaut: %d modèles / %d configs éligibles' % (len(el), cfgCount))
picks = collections.Counter()
recent = L.table()
for i in range(400):
    info = vehLib.pick(el, L.eval('math.random'), recent)
    picks[info.model] += 1
    assert not info.cats['camion'] or info.cats['sport'], 'camion tiré alors que décoché: ' + info.model
    assert info.variant in ('usine', 'custom'), info.variant
print('tirages: %d modèles différents sur 400, le plus fréquent %s' % (len(picks), picks.most_common(3)))

# seulement les camions
vs.cats = L.eval('{camion=true}')
el2, c2 = vehLib.eligibleModels(pool, vs)
print('camions seulement:', len(el2), 'modèles :', sorted([el2[i].model.key for i in range(1, len(el2) + 1)])[:30])

# liste noire
vs.cats = L.eval('{citadine=true, berline=true}')
vs.blacklist = L.eval("{covet=true}")
el3, _ = vehLib.eligibleModels(pool, vs)
assert all(el3[i].model.key != 'covet' for i in range(1, len(el3) + 1)), 'blacklist ignorée'
summ = vehLib.modelSummaries(pool, vs)
banned = [summ[i].key for i in range(1, len(summ) + 1) if summ[i].banned]
assert banned == ['covet'], banned
print('liste noire OK, résumé UI:', len(summ), 'modèles')
print('VEHICLE TESTS OK')
