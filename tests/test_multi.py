"""Multijoueur BeamMP hors du jeu : le vrai plugin serveur (BeamMP/Resources/Server/LivraisonLibre/main.lua)
sur un faux serveur BeamMP, et des joueurs simulés (mod complet + jeu simulé, chacun dans son propre Lua),
reliés comme sur un serveur : messages client -> serveur -> clients.

    python tests/run.py test_multi.py
"""
import math
import os

from lupa import luajit21

HERE = os.path.dirname(os.path.abspath(__file__)).replace('\\', '/')
ROOT = os.path.dirname(HERE)
MOD = ROOT + '/LivraisonLibre'
PLUGIN = ROOT + '/BeamMP/Resources/Server/LivraisonLibre/main.lua'

passed = failed = 0


def check(cond, name, extra=None):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print('  FAIL: ' + name + ('' if extra is None else ' -> ' + str(extra)))


def runtime():
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path = %r .. '/?.lua;' .. %r .. '/?.lua;' .. package.path" % (MOD, HERE))
    lua.globals()['MOD_ROOT'] = MOD
    lua.globals()['TEST_DIR'] = HERE
    return lua


def values(t):
    if t is None:
        return []
    return [t[i] for i in range(1, len(t) + 1)]


SERVER_MOCK = r"""
OUT, HANDLERS, PLAYERS, CHAT = {}, {}, {}, {}
MP = {}
function MP.RegisterEvent(ev, fname) HANDLERS[ev] = fname end
function MP.TriggerClientEvent(id, ev, data) OUT[#OUT + 1] = {id = id, ev = ev, data = data}; return true end
function MP.GetPlayerName(id) return PLAYERS[id] end
function MP.SendChatMessage(id, msg) CHAT[#CHAT + 1] = {id = id, msg = msg} end
local json = dofile(TEST_DIR .. '/json_lite.lua')
Util = {JsonEncode = json.encode, JsonDecode = json.decode}
JSON = json
function SRV_event(ev, id, data)
  local f = HANDLERS[ev] and _G[HANDLERS[ev]]
  if f then f(id, data) end
end
function SRV_drain() local o = OUT; OUT = {}; return o end
"""


class Server:
    def __init__(self):
        self.lua = runtime()
        self.lua.execute(SERVER_MOCK)
        self.lua.execute(open(PLUGIN, encoding='utf-8').read())
        self.json = self.lua.globals()['JSON']

    def connect(self, pid, name):
        self.lua.globals()['PLAYERS'][pid] = name

    def event(self, ev, pid, data):
        self.lua.globals()['SRV_event'](ev, pid, data)

    def disconnect(self, pid):
        self.event('onPlayerDisconnect', pid, None)

    def drain(self):
        return [(m['id'], m['ev'], m['data']) for m in values(self.lua.globals()['SRV_drain']())]

    def decode(self, data):
        return self.json['decode'](data)

    def encode(self, tbl):
        return self.json['encode'](self.lua.table_from(tbl, recursive=True))


class Client:
    def __init__(self, pid, name, x, y, session=True):
        self.pid, self.name = pid, name
        self.lua = runtime()
        g = self.lua.globals()
        g['MP_ID'], g['MP_NAME'], g['OWN_X'], g['OWN_Y'] = pid, name, x, y
        g['MP_SESSION'] = session
        self.lua.execute(open(HERE + '/multi_client.lua', encoding='utf-8').read())
        self.g = g
        self.M = g['M']

    def frames(self, n):
        self.g['frames'](n)

    def outbox(self):
        return [(m['name'], m['data']) for m in values(self.g['MP_drain']())]

    def receive(self, ev, data):
        self.g['MP_receive'](ev, data)

    def sess(self):
        return self.g['sess']()

    def phase(self):
        s = self.sess()
        return s['phase'] if s is not None else None

    def veh(self):
        v = self.g['myVeh']()
        return v

    def pos(self):
        p = self.veh()['pos']
        return (p['x'], p['y'], p['z'])

    def zone(self):
        z = self.g['ENV']['lastZone']
        return None if z is None else {k: z[k] for k in ('x', 'y', 'z', 'fx', 'fy', 'w', 'l')}

    def records(self):
        j = self.g['ENV']['files']['/settings/livraisonLibre/livraisons.json']
        return values(j['records']) if j is not None else []

    def messages(self):
        return values(self.g['ENV']['messages'])


class Net:
    """faux serveur BeamMP : achemine les messages entre les joueurs et le plugin"""
    def __init__(self, server, clients):
        self.server, self.clients, self.log = server, list(clients), []

    def pump(self):
        moved = True
        while moved:
            moved = False
            for c in self.clients:
                for ev, data in c.outbox():
                    self.log.append(('c%d' % c.pid, ev))
                    if self.server:
                        self.server.event(ev, c.pid, data)
                    moved = True
            if self.server:
                for pid, ev, data in self.server.drain():
                    self.log.append(('s>%d' % pid, ev))
                    for c in self.clients:
                        if pid == -1 or c.pid == pid:
                            c.receive(ev, data)
                    moved = True

    def run(self, n=60, step=5):
        for _ in range(max(1, n // step)):
            for c in self.clients:
                c.frames(step)
            self.pump()

    def until(self, cond, limit=1200, step=5):
        for _ in range(limit // step):
            if cond():
                return True
            self.run(step, step)
        return cond()


def dist2d(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def overlap(a, b):
    # zones rectangulaires (axes de a) : se chevauchent-elles ?
    rx, ry = a['fy'], -a['fx']
    dx, dy = b['x'] - a['x'], b['y'] - a['y']
    along, side = abs(dx * a['fx'] + dy * a['fy']), abs(dx * rx + dy * ry)
    return along < (a['l'] + b['l']) / 2 - 0.1 and side < (a['w'] + b['w']) / 2 - 0.1


def test_plugin():
    print('-- plugin serveur : groupe, chef, livraisons, résultats')
    s = Server()
    for pid, name in ((0, 'Alice'), (1, 'Bob'), (2, 'Chloé'), (3, 'Dan')):
        s.connect(pid, name)
    enc = s.encode
    s.event('LL_join', 0, enc({'v': 1}))
    out = s.drain()
    check(len(out) == 1 and out[0][1] == 'LL_group' and out[0][0] == 0, 'premier joueur : groupe envoyé', out)
    g = s.decode(out[0][2])
    check(g['leader'] == 0 and len(values(g['members'])) == 1, 'premier joueur : chef', g and dict(g))
    s.event('LL_join', 1, enc({'v': 1}))
    out = s.drain()
    check(sorted(o[0] for o in out if o[1] == 'LL_group') == [0, 1], 'deuxième joueur : groupe envoyé aux deux', out)
    s.event('LL_propose', 1, enc({'level': 'x'}))
    check(not [o for o in s.drain() if o[1] == 'LL_round'], 'livraison proposée par un autre que le chef : ignorée')
    s.event('LL_propose', 0, enc({'level': 'x', 'starts': [{'x': 1}], 'dests': [{'x': 2}]}))
    rounds = {o[0]: s.decode(o[2]) for o in s.drain() if o[1] == 'LL_round'}
    check(set(rounds) == {0, 1}, 'livraison envoyée à tout le groupe', list(rounds))
    check(rounds.get(0) and rounds[0]['slot'] == 1 and rounds[1]['slot'] == 2 and rounds[0]['round'] == rounds[1]['round'] == 1,
          'places : 1 pour le chef, 2 pour le suivant', {k: (v['slot'], v['round']) for k, v in rounds.items()})
    check(rounds.get(1) and rounds[1]['mission']['level'] == 'x', 'livraison transmise telle quelle')
    s.event('LL_done', 1, enc({'round': 7, 'result': 'Livrée', 'time': 60}))
    check(not s.drain(), 'résultat d\'une autre livraison : ignoré')
    s.event('LL_done', 1, enc({'round': 1, 'result': 'Livrée', 'time': 61.5}))
    out = s.drain()
    res = [s.decode(o[2]) for o in out if o[1] == 'LL_result']
    check(len(res) == 2 and res[0]['name'] == 'Bob' and res[0]['time'] == 61.5 and not [o for o in out if o[1] == 'LL_roundEnd'],
          'résultat de Bob envoyé à tous, livraison pas finie', out)
    s.event('LL_done', 1, enc({'round': 1, 'result': 'Livrée', 'time': 50}))
    check(not s.drain(), 'deuxième résultat du même joueur : ignoré')
    s.event('LL_done', 0, enc({'round': 1, 'result': 'Temps écoulé', 'time': 90}))
    out = s.drain()
    ends = [s.decode(o[2]) for o in out if o[1] == 'LL_roundEnd']
    check(len(ends) == 2 and ends[0]['results']['1']['result'] == 'Livrée' and ends[0]['results']['0']['result'] == 'Temps écoulé',
          'tout le groupe a fini : fin de la livraison avec les résultats', out)
    s.event('LL_join', 2, enc({'v': 1}))
    out = s.drain()
    check([o for o in out if o[1] == 'LL_group'] and not [o for o in out if o[1] == 'LL_round'],
          'arrivée après la fin d\'une livraison : groupe, pas de livraison en cours')
    s.event('LL_propose', 0, enc({'level': 'y'}))
    rounds = {o[0]: s.decode(o[2]) for o in s.drain() if o[1] == 'LL_round'}
    check({k: v['slot'] for k, v in rounds.items()} == {0: 1, 1: 2, 2: 3} and rounds[2]['round'] == 2,
          'livraison 2 : places dans l\'ordre d\'arrivée', {k: v['slot'] for k, v in rounds.items()})
    s.event('LL_join', 3, enc({'v': 1}))
    out = s.drain()
    late = [s.decode(o[2]) for o in out if o[1] == 'LL_round']
    check(len(late) == 1 and late[0]['slot'] == 4 and late[0]['round'] == 2, 'arrivée pendant une livraison : place libre suivante', late)
    s.event('LL_leave', 0, enc({}))
    out = s.drain()
    groups = [s.decode(o[2]) for o in out if o[1] == 'LL_group']
    check(groups and all(gr['leader'] == 1 for gr in groups) and len(groups) == 3, 'le chef part : le suivant devient chef', groups)
    for pid in (1, 2):
        s.event('LL_done', pid, enc({'round': 2, 'result': 'Livrée', 'time': 40 + pid}))
    s.drain()
    s.disconnect(3)
    out = s.drain()
    check(len([o for o in out if o[1] == 'LL_roundEnd']) == 2, 'joueur déconnecté : la livraison se termine sans lui', out)
    s.event('LL_join', 3, enc({'v': 2}))
    check(any(c['id'] == 3 for c in values(s.lua.globals()['CHAT'])), 'version du mod différente : message au joueur')
    s.drain()
    for pid in range(10, 16):
        s.connect(pid, 'J%d' % pid)
        s.event('LL_join', pid, enc({'v': 1}))
    s.drain()
    s.connect(20, 'Neuvième')
    s.event('LL_join', 20, enc({'v': 1}))
    out = s.drain()
    check([o for o in out if o[1] == 'LL_full' and o[0] == 20], 'groupe complet (8) : le 9e est prévenu', out)


def test_two_players():
    print('-- partie à deux : même véhicule, départs et arrivées côte à côte, résultats, livraison suivante')
    server = Server()
    server.connect(0, 'Alice')
    server.connect(1, 'Bob')
    a = Client(0, 'Alice', 0, 0)
    b = Client(1, 'Bob', 600, 600)
    net = Net(server, [a, b])
    a.M.start()
    net.pump()
    check(net.until(lambda: a.phase() == 'driving'), 'chef : livraison lancée', a.phase())
    sa = a.sess()
    check(sa['multi'] is not None and sa['multi']['leader'] is True and len(values(sa['multi']['players'])) == 1,
          'chef : groupe d\'un joueur, c\'est lui le chef')
    b.M.start()
    net.pump()
    check(net.until(lambda: b.phase() == 'driving'), 'deuxième joueur : il rejoint la livraison en cours', b.phase())
    sb = b.sess()
    check(sb['vehicle']['model'] == sa['vehicle']['model'] and sb['vehicle']['name'] == sa['vehicle']['name'],
          'même véhicule pour les deux', (sa['vehicle']['name'], sb['vehicle']['name']))
    check(a.g['ENV']['configs'] is not None and sa['vehicle']['source'] == 'BeamNG - Official', 'en groupe : véhicule officiel',
          sa['vehicle']['source'])
    d = dist2d(a.pos(), b.pos())
    check(2.5 <= d <= 8, 'départs côte à côte (à côté, ou juste derrière sur une route étroite)', round(d, 2))
    za, zb = a.zone(), b.zone()
    check(za and zb and dist2d((za['x'], za['y']), (zb['x'], zb['y'])) < 15 and not overlap(za, zb),
          'même destination, chacun sa place (sans chevauchement)', (za, zb))
    check(sb['multi']['leader'] is False and sb['multi']['leaderName'] == 'Alice', 'deuxième joueur : chef = Alice', dict(sb['multi']))
    for c in (a, b):
        check(c.g['vehCount']() == 1 and len(values(c.g['ENV']['deleted'])) == 0,
              '%s : véhicule remplacé sur place (aucun nouveau véhicule, aucune suppression)' % c.name, c.g['vehCount']())
        check(len(values(c.g['ENV']['traffic']['calls'])) == 0, '%s : trafic du jeu laissé tel quel' % c.name)
    # Bob livre, Alice abandonne
    b.g['driveAway']()
    b.g['parkAndValidate']()
    net.pump()
    check(b.phase() == 'summary', 'Bob : livraison validée', b.phase())
    net.run(120)
    check(b.phase() == 'summary', 'Bob : attend le groupe (pas de livraison suivante tout seul)', b.phase())
    pa = values(a.sess()['multi']['players'])
    bob = [p for p in pa if p['name'] == 'Bob']
    check(bob and bob[0]['result'] == 'Livrée' and bob[0]['rank'] == 1, 'Alice voit le résultat de Bob (1er)', [dict(p) for p in pa])
    check(any('Bob a livré' in m for m in a.messages()), 'Alice : message « Bob a livré en … »')
    check(any(n == 'Alice' for n in values(b.sess()['multi']['waitingFor'])), 'Bob : en attente d\'Alice')
    a.M.skip()
    net.pump()
    check(a.phase() == 'failed', 'Alice : livraison abandonnée', a.phase())
    first_model = sa['vehicle']['model']
    check(net.until(lambda: a.phase() == 'driving' and b.phase() == 'driving', limit=1500),
          'tout le groupe a fini : livraison suivante pour les deux', (a.phase(), b.phase()))
    check(a.sess()['vehicle']['model'] == b.sess()['vehicle']['model'], 'livraison 2 : même véhicule pour les deux')
    ra, rb = a.records(), b.records()
    check(len(ra) == 1 and ra[0]['result'] == 'Passée' and len(rb) == 1 and rb[0]['result'] == 'Livrée',
          'journal de chacun : sa livraison', ([r['result'] for r in ra], [r['result'] for r in rb]))
    # Alice arrête : Bob devient chef et continue seul
    a.M.stop()
    net.pump()
    check(b.sess()['multi']['leader'] is True and len(values(b.sess()['multi']['players'])) == 1, 'Alice partie : Bob est chef')
    b.g['driveAway']()
    b.g['parkAndValidate']()
    net.pump()
    check(net.until(lambda: b.phase() == 'driving' and len(b.records()) == 2, limit=1500), 'Bob, nouveau chef : livraison suivante',
          (b.phase(), len(b.records())))
    check(not [e for e in net.log if e[1] == 'LL_join' and e[0] == 'c0'][1:], 'Alice : un seul « rejoindre »')
    return first_model


def test_three_players():
    print('-- partie à trois : trois places distinctes ; le chef force la livraison suivante')
    server = Server()
    names = {0: 'Alice', 1: 'Bob', 2: 'Chloé'}
    for pid, name in names.items():
        server.connect(pid, name)
    clients = [Client(pid, name, 300 * pid, 0) for pid, name in names.items()]
    net = Net(server, clients)
    for c in clients:
        c.M.start()
        net.pump()
        check(net.until(lambda: c.phase() == 'driving'), '%s : livraison du groupe lancée' % c.name, c.phase())
    pos = [c.pos() for c in clients]
    zones = [c.zone() for c in clients]
    apart = all(dist2d(pos[i], pos[j]) >= 2.5 for i in range(3) for j in range(i + 1, 3))
    check(apart, 'trois départs distincts (au moins 2,5 m entre deux voitures)', [tuple(round(x, 1) for x in p[:2]) for p in pos])
    sep = all(not overlap(zones[i], zones[j]) and not overlap(zones[j], zones[i]) for i in range(3) for j in range(i + 1, 3))
    near = all(dist2d((zones[0]['x'], zones[0]['y']), (z['x'], z['y'])) < 25 for z in zones)
    check(sep and near, 'trois places d\'arrivée voisines, sans chevauchement', zones)
    models = {c.sess()['vehicle']['model'] for c in clients}
    check(len(models) == 1, 'même véhicule pour les trois', models)
    a = clients[0]
    a.g['driveAway']()
    a.g['parkAndValidate']()
    net.pump()
    check(a.phase() == 'summary', 'Alice (chef) a livré', a.phase())
    a.M.next()  # le chef n'attend pas : livraison suivante pour tout le groupe
    net.pump()
    check(net.until(lambda: all(c.phase() == 'driving' for c in clients), limit=600), 'livraison suivante forcée : tout le monde la reçoit',
          [c.phase() for c in clients])
    for c in clients[1:]:
        recs = c.records()
        check(len(recs) == 1 and recs[0]['result'] == 'Passée', '%s : livraison interrompue notée « Passée »' % c.name,
              [r['result'] for r in recs])
    b = clients[1]
    b.M.next()
    net.pump()
    t = b.g['ENV']['events']['LivraisonLibreToast']
    check(t is not None and 'chef' in t['msg'] and b.phase() == 'driving', 'Bob : « suivante » réservée au chef',
          (t and t['msg'], b.phase()))


def test_fallbacks():
    print('-- secours : serveur sans plugin, partie solo')
    c = Client(5, 'Solo', 0, 0)
    net = Net(None, [c])  # messages perdus : pas de plugin sur ce serveur
    c.M.start()
    net.run(60)
    check(c.phase() == 'waiting', 'multijoueur : attente de la réponse du serveur', c.phase())
    check(net.until(lambda: c.phase() == 'driving', limit=600), 'sans plugin : livraisons en solo après quelques secondes', c.phase())
    check(c.sess()['multi'] is None, 'sans plugin : pas de groupe')
    check(c.g['vehCount']() == 1, 'sans plugin, en partie BeamMP : véhicule remplacé sur place', c.g['vehCount']())
    s = Client(6, 'Hors-ligne', 0, 0, session=False)
    net2 = Net(None, [s])
    s.M.start()
    net2.run(60)
    check(s.phase() == 'driving' and not [e for e in net2.log if e[1] == 'LL_join'], 'hors BeamMP : livraison directe, aucun message')


def main():
    test_plugin()
    test_two_players()
    test_three_players()
    test_fallbacks()
    print('MULTI TESTS: %d passed, %d failed' % (passed, failed))
    return failed == 0


if __name__ == '__main__':
    import sys
    sys.exit(0 if main() else 1)
