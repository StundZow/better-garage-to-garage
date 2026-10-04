-- Charge l'extension Livraison Libre au démarrage et la garde active entre les maps.
setExtensionUnloadMode('livraisonLibre', 'manual')
if extensions and extensions.load then extensions.load('livraisonLibre') end
