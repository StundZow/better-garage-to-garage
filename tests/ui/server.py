"""Banc de test de l'interface (sans le jeu) : python tests/ui/server.py puis http://localhost:8791
Paramètres d'URL : ?view=app|resume|both  &scenario=idle|far|near|inzone|validating|pursuit|summary|failed|lost
                   &tab=mission|lieux|v|trafic|points|stats|param  &summary=ok|ko
"""
import http.server
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.normpath(os.path.join(HERE, '..', '..', 'LivraisonLibre'))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8791


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        path = path.split('?', 1)[0].split('#', 1)[0]
        root = MOD if path.startswith('/ui/') else HERE
        return os.path.join(root, *path.lstrip('/').split('/'))

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


if __name__ == '__main__':
    print('Banc de test UI : http://localhost:%d' % PORT)
    http.server.ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
