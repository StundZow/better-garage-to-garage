"""Lance les tests Lua du mod hors du jeu (LuaJIT via lupa).

    pip install lupa
    python tests/run.py                 # syntaxe + modules + simulation de parties
    python tests/run.py test_sim.lua    # un seul fichier
"""
import io
import os
import sys

from lupa import luajit21

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

HERE = os.path.dirname(os.path.abspath(__file__)).replace('\\', '/')
MOD = os.path.normpath(os.path.join(HERE, '..', 'LivraisonLibre')).replace('\\', '/')
DEFAULT = ['test_syntax.lua', 'test_pure.lua', 'test_sim.lua']


def new_runtime():
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path = %r .. '/?.lua;' .. %r .. '/?.lua;' .. package.path" % (MOD, HERE))
    lua.globals()['MOD_ROOT'] = MOD
    lua.globals()['TEST_DIR'] = HERE
    return lua


def run(script):
    lua = new_runtime()
    with open(os.path.join(HERE, script), encoding='utf-8') as f:
        code = f.read()
    try:
        lua.execute(code)
    except Exception as e:  # erreur Lua ou assertion d'échec
        print('LUA ERROR in', script, ':', e)
        return False
    return True


if __name__ == '__main__':
    ok = True
    for s in (sys.argv[1:] or DEFAULT):
        print('=' * 20, s)
        ok = run(s) and ok
    sys.exit(0 if ok else 1)
