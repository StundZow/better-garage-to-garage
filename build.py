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

# Paquet pour un serveur BeamMP : le mod (envoyé par le serveur aux joueurs) et le plugin qui relie les joueurs,
# à copier dans le dossier du serveur
SERVER_SRC = os.path.join(ROOT, 'BeamMP', 'Resources', 'Server', 'LivraisonLibre')
MP_OUT = os.path.join(DIST, 'LivraisonLibre-BeamMP-serveur.zip')
LISEZMOI = '''Livraison Libre - multijoueur BeamMP

Sur le serveur BeamMP, copie le dossier Resources de ce zip dans le dossier du serveur (celui de
BeamMP-Server), en le fusionnant avec le dossier Resources qui s'y trouve :
  - Resources/Client/LivraisonLibre.zip : le mod, envoyé automatiquement aux joueurs ;
  - Resources/Server/LivraisonLibre/main.lua : le plugin qui relie les joueurs.
Puis redémarre le serveur.

En jeu, chacun ouvre l'app Livraison Libre (menu des apps de l'interface) et clique sur
« Lancer les livraisons ». Le premier à lancer choisit les livraisons (le chef) ; les autres reçoivent
la même : même véhicule, départs et arrivées côte à côte. La livraison suivante part quand tout le
groupe a fini (livrée, ratée ou passée). En multijoueur, le mod ne crée ni trafic ni police.
'''
with zipfile.ZipFile(MP_OUT, 'w', zipfile.ZIP_DEFLATED) as zf:
    zf.write(OUT, 'Resources/Client/LivraisonLibre.zip')
    for f in sorted(os.listdir(SERVER_SRC)):
        zf.write(os.path.join(SERVER_SRC, f), 'Resources/Server/LivraisonLibre/' + f)
    zf.writestr('LISEZMOI.txt', LISEZMOI.replace('\n', '\r\n'))
print('serveur BeamMP -> %s (%d octets)' % (MP_OUT, os.path.getsize(MP_OUT)))
