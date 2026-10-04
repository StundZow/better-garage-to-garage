angular.module('beamng.apps')
.directive('livraisonLibre', ['$filter', '$timeout', function ($filter, $timeout) {
  return {
    templateUrl: '/ui/modules/apps/LivraisonLibre/app.html',
    replace: false,
    restrict: 'E',
    scope: true,
    link: function (scope, element) {
      var STORE_KEY = 'livraisonLibre.ui'
      var DIST_MIN = 100, DIST_MAX = 30000
      var NUMERIC = ['minDist', 'maxDist', 'zoneScale', 'pavedThreshold', 'avgSpeedKmh', 'timeBonus', 'summaryDuration']
      var TRAFFIC_NUMERIC = ['amount', 'parked', 'strictness', 'wantedLevel', 'policeRatio']

      var CAT_SINGULAR = {
        citadine: 'Citadine', berline: 'Berline', familiale: 'Break / monospace', coupe: 'Coupé / cabriolet',
        sport: 'Sportive', suv: 'SUV / 4x4', pickup: 'Pick-up', utilitaire: 'Utilitaire', camion: 'Camion',
        bus: 'Bus', toutterrain: 'Tout-terrain', engin: 'Engin', autre: 'Véhicule'
      }
      var SRC_LABEL = { officiel: 'Officiel', mod: 'Mod', perso: 'Config perso' }

      var translate
      try { translate = $filter('translate') } catch (e) { translate = function (s) { return s } }

      function loadUi () {
        try { return JSON.parse(localStorage.getItem(STORE_KEY)) || {} } catch (e) { return {} }
      }
      function saveUi () {
        try { localStorage.setItem(STORE_KEY, JSON.stringify({ tab: scope.ui.tab, collapsed: scope.ui.collapsed })) } catch (e) {}
        // aussi côté jeu, pour retrouver l'interface telle quelle au prochain lancement
        if (window.bngApi) api('setUiPrefs', { tab: scope.ui.tab, collapsed: scope.ui.collapsed })
      }

      var saved = loadUi()
      scope.tabs = [
        { id: 'options', label: 'Mission', icon: 'M3 17v2h6v-2H3zM3 5v2h10V5H3zm10 16v-2h8v-2h-8v-2h-2v6h2zM7 9v2H3v2h4v2h2V9H7zm14 4v-2H11v2h10zm-6-4h2V7h4V5h-4V3h-2v6z' },
        { id: 'lieux', label: 'Lieux', icon: 'M20.5 3l-.16.03L15 5.1 9 3 3.36 4.9c-.21.07-.36.25-.36.48V20.5c0 .28.22.5.5.5l.16-.03L9 18.9l6 2.1 5.64-1.9c.21-.07.36-.25.36-.48V3.5c0-.28-.22-.5-.5-.5zM15 19l-6-2.11V5l6 2.11V19z' },
        { id: 'vehicules', label: 'Véhicules', icon: 'M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.66 0-1.21.42-1.42 1.01L3 12v8c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-1h12v1c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-8l-2.08-5.99zM6.5 16c-.83 0-1.5-.67-1.5-1.5S5.67 13 6.5 13s1.5.67 1.5 1.5S7.33 16 6.5 16zm11 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zM5 11l1.5-4.5h11L19 11H5z' },
        { id: 'trafic', label: 'Trafic', icon: 'M20 10h-3V8.86c1.72-.45 3-2 3-3.86h-3V4c0-.55-.45-1-1-1H8c-.55 0-1 .45-1 1v1H4c0 1.86 1.28 3.41 3 3.86V10H4c0 1.86 1.28 3.41 3 3.86V15H4c0 1.86 1.28 3.41 3 3.86V20c0 .55.45 1 1 1h8c.55 0 1-.45 1-1v-1.14c1.72-.45 3-2 3-3.86h-3v-1.14c1.72-.45 3-2 3-3.86zm-8 9c-1.11 0-2-.9-2-2s.89-2 2-2c1.1 0 2 .9 2 2s-.89 2-2 2zm0-5c-1.11 0-2-.9-2-2s.89-2 2-2c1.1 0 2 .9 2 2s-.89 2-2 2zm0-5c-1.11 0-2-.9-2-2 0-1.11.89-2 2-2 1.1 0 2 .89 2 2 0 1.1-.89 2-2 2z' },
        { id: 'points', label: 'Points', icon: 'M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5a2.5 2.5 0 010-5 2.5 2.5 0 010 5z' },
        { id: 'stats', label: 'Stats', icon: 'M5 9.2h3V19H5zM10.6 5h2.8v14h-2.8zm5.6 8H19v6h-2.8z' },
        { id: 'parametres', label: 'Paramètres', icon: 'M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 00.12-.61l-1.92-3.32a.488.488 0 00-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 00-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 00-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z' }
      ]
      scope.kinds = [
        { id: 'road', label: 'Bord de route' },
        { id: 'parking', label: 'Parkings' },
        { id: 'poi', label: "Lieux d'intérêt" },
        { id: 'home', label: 'Maisons & allées' }
      ]
      scope.ui = {
        tab: saved.tab || 'options', collapsed: !!saved.collapsed,
        search: '', onlyBanned: false, vehLimit: 40,
        pointName: '', renaming: null, renameValue: '', confirmDelete: null,
        toast: null, confirm: null, minPos: 0, maxPos: 0
      }
      scope.state = null
      scope.s = null
      scope.st = {}
      scope.sess = null
      scope.hud = {}
      scope.vehModels = []
      scope.vehView = []

      var pushTimer = null
      var pushPending = false
      var toastTimer = null
      var firstState = true

      // ---------- pont Lua ----------
      function lua (cmd, cb) { bngApi.engineLua(cmd, cb) }
      function api (fn) {
        var args = Array.prototype.slice.call(arguments, 1).map(function (a) { return bngApi.serializeToLua(a) }).join(', ')
        lua('if livraisonLibre then livraisonLibre.' + fn + '(' + args + ') end')
      }

      function isMap (o) { return o && typeof o === 'object' && !Array.isArray(o) }
      function asMap (o) { return isMap(o) ? o : {} }
      function anyTrue (o) {
        for (var k in o) { if (o[k] === true) return true }
        return false
      }

      function normalizeSettings (s) {
        if (!s) return s
        s.locKinds = asMap(s.locKinds)
        s.veh = asMap(s.veh)
        s.veh.cats = asMap(s.veh.cats)
        s.veh.epochs = asMap(s.veh.epochs)
        s.veh.variants = asMap(s.veh.variants)
        s.veh.sources = asMap(s.veh.sources)
        s.veh.blacklist = asMap(s.veh.blacklist)
        s.traffic = asMap(s.traffic)
        s.ui = asMap(s.ui)
        return s
      }

      function cleanSettings (s) {
        var c = JSON.parse(angular.toJson(s))
        NUMERIC.forEach(function (k) { if (c[k] !== undefined) c[k] = parseFloat(c[k]) })
        if (c.traffic) TRAFFIC_NUMERIC.forEach(function (k) { if (c.traffic[k] !== undefined) c.traffic[k] = parseFloat(c.traffic[k]) })
        delete c.ui
        var bl = {}
        for (var k in c.veh.blacklist) { if (c.veh.blacklist[k] === true) bl[k] = true }
        c.veh.blacklist = bl
        return c
      }

      // ---------- distance (curseur logarithmique) ----------
      function niceDist (d) {
        if (d < 1000) return Math.round(d / 50) * 50
        if (d < 5000) return Math.round(d / 100) * 100
        return Math.round(d / 500) * 500
      }
      function posToDist (p) { return niceDist(DIST_MIN * Math.pow(DIST_MAX / DIST_MIN, (+p || 0) / 1000)) }
      function distToPos (d) {
        d = Math.min(DIST_MAX, Math.max(DIST_MIN, +d || DIST_MIN))
        return Math.round(1000 * Math.log(d / DIST_MIN) / Math.log(DIST_MAX / DIST_MIN))
      }
      function syncDistPos () {
        if (!scope.s) return
        scope.ui.minPos = distToPos(scope.s.minDist)
        scope.ui.maxPos = distToPos(scope.s.maxDist)
      }
      scope.onDistSlider = function (which) {
        var mn = posToDist(scope.ui.minPos), mx = posToDist(scope.ui.maxPos)
        if (which === 'min' && mn > mx - 100) { mx = Math.min(DIST_MAX, mn + 200); scope.ui.maxPos = distToPos(mx) }
        if (which === 'max' && mx < mn + 100) { mn = Math.max(DIST_MIN, mx - 200); scope.ui.minPos = distToPos(mn) }
        scope.s.minDist = mn
        scope.s.maxDist = mx
        scope.pushSoon()
      }

      // ---------- envoi des réglages ----------
      scope.push = function () {
        if (!scope.s) return
        $timeout.cancel(pushTimer)
        pushPending = false
        api('setSettings', cleanSettings(scope.s))
      }
      scope.pushSoon = function () {
        pushPending = true
        $timeout.cancel(pushTimer)
        pushTimer = $timeout(scope.push, 300)
      }
      scope.set = function (key, value) {
        scope.s[key] = value
        scope.push()
      }
      scope.toggleKind = function (id) {
        scope.s.locKinds[id] = !scope.s.locKinds[id]
        if (!anyTrue(scope.s.locKinds)) {
          scope.s.locKinds[id] = true
          toast('warn', 'Garde au moins un type de lieu.')
          return
        }
        scope.push()
      }
      scope.toggleVeh = function (group, id) {
        var g = scope.s.veh[group]
        g[id] = !g[id]
        if (!anyTrue(g) && group !== 'cats') {
          g[id] = true
          toast('warn', 'Garde au moins une option dans ce groupe.')
          return
        }
        scope.push()
      }
      scope.setTraffic = function (key, value) {
        scope.s.traffic[key] = value
        scope.push()
      }
      scope.setAllVeh = function (group, value) {
        var list = (scope.state && scope.state.meta && scope.state.meta.categories) || []
        list.forEach(function (c) { scope.s.veh[group][c.id] = value })
        scope.push()
      }

      // ---------- actions ----------
      scope.start = function () { api('start') }
      scope.call = function (fn) { api(fn) }
      scope.callArg = function (fn, a) { api(fn, a) }
      scope.toggleCollapsed = function () {
        scope.ui.collapsed = !scope.ui.collapsed
        saveUi()
        if (!scope.ui.collapsed && !scope.sess) onTab(scope.ui.tab)
      }
      scope.setTab = function (id) {
        scope.ui.tab = id
        saveUi()
        onTab(id)
      }
      function onTab (id) {
        if (id === 'vehicules') api('requestVehicles')
        if (id === 'lieux' && scope.state && scope.state.level && !scope.state.levelReady) api('requestMapInfo')
        if (id === 'points' || id === 'trafic' || id === 'stats') api('requestState')
      }

      scope.confirm = function (fn, text) { scope.ui.confirm = { fn: fn, text: text } }
      scope.doConfirm = function () {
        var c = scope.ui.confirm
        scope.ui.confirm = null
        if (c) api(c.fn)
      }

      // ---------- points ----------
      scope.addPoint = function () {
        api('addPoint', scope.ui.pointName || '')
        scope.ui.pointName = ''
      }
      scope.startRename = function (p) {
        scope.ui.renaming = p.id
        scope.ui.renameValue = p.name
      }
      scope.saveRename = function (p) {
        if (scope.ui.renameValue && scope.ui.renameValue.trim()) api('renamePoint', p.id, scope.ui.renameValue.trim())
        scope.ui.renaming = null
      }
      scope.removePoint = function (p) {
        if (scope.ui.confirmDelete === p.id) {
          api('removePoint', p.id)
          scope.ui.confirmDelete = null
          return
        }
        scope.ui.confirmDelete = p.id
        $timeout(function () { if (scope.ui.confirmDelete === p.id) scope.ui.confirmDelete = null }, 2500)
      }

      // ---------- liste noire ----------
      scope.refreshVehView = function () {
        var q = (scope.ui.search || '').toLowerCase().trim()
        var bl = (scope.s && scope.s.veh && scope.s.veh.blacklist) || {}
        scope.vehView = scope.vehModels.filter(function (m) {
          m.banned = bl[m.key] === true
          if (scope.ui.onlyBanned && !m.banned) return false
          if (!q) return true
          return ((m.brand || '') + ' ' + (m.name || '') + ' ' + m.key).toLowerCase().indexOf(q) >= 0
        })
      }
      scope.toggleBan = function (m) {
        m.banned = !m.banned
        if (m.banned) scope.s.veh.blacklist[m.key] = true
        else delete scope.s.veh.blacklist[m.key]
        api('setBlacklisted', m.key, m.banned)
        if (scope.ui.onlyBanned) scope.refreshVehView()
      }
      scope.bannedCount = function () {
        var n = 0
        var bl = (scope.s && scope.s.veh && scope.s.veh.blacklist) || {}
        for (var k in bl) { if (bl[k] === true) n++ }
        return n
      }

      // ---------- affichage ----------
      scope.fmtDist = function (m) {
        m = +m || 0
        if (m >= 1000) return (m / 1000).toFixed(m >= 10000 ? 0 : 1).replace('.', ',') + ' km'
        return Math.round(m) + ' m'
      }
      scope.fmtTime = function (sec) {
        sec = Math.max(0, Math.round(+sec || 0))
        var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60
        var pad = function (n) { return (n < 10 ? '0' : '') + n }
        return h > 0 ? h + ':' + pad(m) + ':' + pad(s) : m + ':' + pad(s)
      }
      scope.fmtInt = function (v) {
        return String(Math.round(+v || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')
      }
      scope.catLabel = function (id) { return CAT_SINGULAR[id] || 'Véhicule' }
      scope.srcLabel = function (id) { return SRC_LABEL[id] || id }
      scope.tr = function (s) {
        if (typeof s !== 'string') return s
        if (/^[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)+$/.test(s)) {
          var t = translate(s)
          if (t && t !== s && t.indexOf('ui.') !== 0 && t.indexOf('levels.') !== 0) return t
          var parts = s.split('.').filter(function (p) { return ['name', 'title', 'description', 'desc'].indexOf(p) < 0 })
          var last = (parts[parts.length - 1] || s).replace(/[_\-]+/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2')
          return last.charAt(0).toUpperCase() + last.slice(1)
        }
        return s
      }
      scope.headerToggleTitle = function () {
        if (scope.sess) return scope.ui.collapsed ? 'Afficher les détails' : 'Masquer les détails'
        return scope.ui.collapsed ? 'Afficher les réglages' : 'Réduire'
      }
      scope.trafficPill = function () {
        var t = scope.state && scope.state.settings && scope.state.settings.traffic
        if (!t || t.mode === 'keep') return 'Trafic inchangé'
        if (t.mode === 'off') return 'Sans trafic'
        var p = t.police === 'wanted' ? ' · recherché' : (t.police === 'patrol' ? ' · police' : '')
        return 'Trafic ' + t.amount + p
      }
      scope.policeSplit = function () {
        var t = scope.s && scope.s.traffic
        if (!t) return ''
        var amount = Math.max(1, Math.round(+t.amount || 1))
        var police = Math.max(1, Math.min(amount, Math.round(amount * (+t.policeRatio || 0.25))))
        return Math.round((+t.policeRatio || 0.25) * 100) + ' % · ' + police + ' police / ' + (amount - police) + ' civils'
      }
      scope.strictLabel = function (v) {
        v = +v || 0
        if (v < 0.35) return 'Indulgente'
        if (v < 0.7) return 'Normale'
        return 'Stricte'
      }
      scope.hasTimeLeft = function () {
        return scope.hud && scope.hud.timeLeft !== undefined && scope.hud.timeLeft !== null
      }
      scope.chronoLabel = function () {
        if (scope.hasTimeLeft()) return 'Temps restant'
        var st = scope.hud && scope.hud.chronoState
        if (st === 'wait') return 'Chrono · accélère !'
        if (st === 'stopped') return 'Trajet terminé'
        return 'Chrono trajet'
      }
      scope.policeText = function () {
        var h = scope.hud || {}
        if (h.pursuit > 0) return 'Poursuite ' + h.pursuit
        if (h.traffic && h.traffic.police > 0) return h.traffic.police + ' patrouille' + (h.traffic.police > 1 ? 's' : '')
        return 'Non'
      }
      scope.logoState = function () {
        if (!scope.sess) return 'll-logo-idle'
        if (scope.sess.phase === 'summary') return 'll-logo-green'
        if (scope.hud && scope.hud.inZone) return 'll-logo-blue'
        return ''
      }
      scope.timeClass = function () {
        var t = scope.hud && scope.hud.timeLeft
        if (t === undefined || t === null) return ''
        if (t < 15) return 'll-time-crit'
        if (t < 45) return 'll-time-warn'
        return ''
      }
      scope.statusText = function () {
        var h = scope.hud || {}
        if (h.inVehicle === false) return 'Remonte dans ton véhicule de livraison'
        if (h.inZone) {
          if (h.validation === 'auto') return h.speedKmh > 1.5 ? 'Dans la zone : arrête-toi' : 'Parfait, ne bouge plus…'
          if (h.speedKmh > 1.8) return 'Dans la zone : arrête-toi'
          if (!h.parkBrake) return 'Bien garé ! Serre le frein à main'
          return 'Validation de la livraison…'
        }
        if (h.near) return 'Gare-toi entièrement dans la zone P'
        return 'Suis le GPS jusqu\'à la zone de livraison'
      }
      scope.statusClass = function () {
        var h = scope.hud || {}
        if (h.inVehicle === false) return 'll-st-warn'
        if (h.inZone) return ((h.parkBrake || h.validation === 'auto') && h.speedKmh <= 1.8) ? 'll-st-ok' : 'll-st-in'
        if (h.near) return ''
        return 'll-st-far'
      }

      function toast (kind, msg) {
        scope.ui.toast = { kind: kind || 'info', msg: msg }
        $timeout.cancel(toastTimer)
        toastTimer = $timeout(function () { scope.ui.toast = null }, 5000)
      }

      // ---------- événements Lua ----------
      scope.$on('LivraisonLibreState', function (event, data) {
        scope.$evalAsync(function () {
          if (!data) return
          scope.state = data
          if (!Array.isArray(data.points)) data.points = []
          if (!pushPending) {
            scope.s = normalizeSettings(angular.copy(data.settings))
            syncDistPos()
          }
          scope.st = data.stats || {}
          if (!Array.isArray(scope.st.history)) scope.st.history = []
          scope.sess = data.session || null
          if (!scope.sess) scope.hud = {}
          if (scope.vehModels.length) scope.refreshVehView()
          if (firstState) {
            firstState = false
            var uiPrefs = data.settings && data.settings.ui
            if (uiPrefs && !Array.isArray(uiPrefs)) {
              if (uiPrefs.tab) scope.ui.tab = uiPrefs.tab
              if (uiPrefs.collapsed !== undefined) scope.ui.collapsed = !!uiPrefs.collapsed
            }
            if (!scope.ui.collapsed && !scope.sess) onTab(scope.ui.tab)
          }
        })
      })
      scope.$on('LivraisonLibreHud', function (event, data) {
        scope.$evalAsync(function () { scope.hud = data || {} })
      })
      scope.$on('LivraisonLibreVehicles', function (event, data) {
        scope.$evalAsync(function () {
          scope.vehModels = (data && Array.isArray(data.models)) ? data.models : []
          scope.refreshVehView()
        })
      })
      scope.$on('LivraisonLibreToast', function (event, data) {
        scope.$evalAsync(function () { if (data && data.msg) toast(data.kind, data.msg) })
      })
      scope.$on('LivraisonLibreToggle', function () {
        scope.$evalAsync(function () { scope.toggleCollapsed() })
      })
      scope.$on('$destroy', function () {
        $timeout.cancel(pushTimer)
        $timeout.cancel(toastTimer)
      })

      lua("if not livraisonLibre then setExtensionUnloadMode('livraisonLibre', 'manual'); extensions.load('livraisonLibre') end; if livraisonLibre then livraisonLibre.requestState() end")
    }
  }
}])
