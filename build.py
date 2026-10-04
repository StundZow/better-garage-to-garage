# Construit dist/LivraisonLibre.zip à partir du dossier LivraisonLibre/
import os, zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, 'LivraisonLibre')
DIST = os.path.join(ROOT, 'dist')
OUT = os.path.join(DIST, 'LivraisonLibre.zip')

os.makedirs(DIST, exist_ok=True)
count = 0
with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as zf:
    for base, dirs, files in os.walk(SRC):
        dirs.sort()
        for f in sorted(files):
            full = os.path.join(base, f)
            arc = os.path.relpath(full, SRC).replace(os.sep, '/')
            zf.write(full, arc)
            count += 1
            print('  +', arc)
print('%d fichiers -> %s (%d octets)' % (count, OUT, os.path.getsize(OUT)))
