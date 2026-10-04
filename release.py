"""Publie une nouvelle version de Livraison Libre sur GitHub.

    python release.py 1.3 "Description des changements"

Met à jour le numéro de version (Lua + apps UI), lance les tests, reconstruit
dist/LivraisonLibre.zip, commit + tag, pousse, puis crée la release GitHub avec le zip.
Nécessite git, GitHub CLI (gh) authentifié et lupa (pip install lupa) pour les tests.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
LUA = os.path.join(ROOT, 'LivraisonLibre', 'lua', 'ge', 'extensions', 'livraisonLibre.lua')
APPS = [os.path.join(ROOT, 'LivraisonLibre', 'ui', 'modules', 'apps', name, 'app.json')
        for name in ('LivraisonLibre', 'LivraisonLibreResume')]
ZIP = os.path.join(ROOT, 'dist', 'LivraisonLibre.zip')


def run(*cmd):
    print('>', ' '.join(cmd))
    subprocess.run(cmd, cwd=ROOT, check=True)


def output(*cmd):
    return subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def edit(path, pattern, repl):
    # lecture/écriture en UTF-8 sans BOM, fins de ligne conservées
    with open(path, encoding='utf-8', newline='') as f:
        text = f.read()
    new, n = re.subn(pattern, repl, text, count=1)
    if n != 1:
        sys.exit('Version introuvable dans ' + path)
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(new)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    version, notes = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r'\d+\.\d+(\.\d+)?', version):
        sys.exit('Version invalide : ' + version + ' (ex. 1.3 ou 1.3.1)')
    if version.count('.') == 1:
        version += '.0'
    tag = 'v' + version
    if output('git', 'tag', '--list', tag):
        sys.exit('Le tag ' + tag + ' existe déjà')

    edit(LUA, r"local VERSION = '[^']*'", "local VERSION = '%s'" % version)
    for path in APPS:
        edit(path, r'"version": "[^"]*"', '"version": "%s"' % version)
        json.load(open(path, encoding='utf-8'))  # toujours du JSON valide

    run(sys.executable, os.path.join('tests', 'run.py'))
    run(sys.executable, 'build.py')

    run('git', 'add', '-A')
    run('git', 'commit', '-m', 'Livraison Libre %s\n\n%s' % (version, notes))
    run('git', 'tag', tag)
    run('git', 'push', 'origin', 'HEAD', tag)
    run('gh', 'release', 'create', tag, ZIP, '--title', 'Livraison Libre ' + version, '--notes', notes)
    print('Release %s publiée.' % tag)


if __name__ == '__main__':
    main()
