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
        { id: 'trajet', label: 'Trajet', icon: 'M20.5 3l-.16.03L15 5.1 9 3 3.36 4.9c-.21.07-.36.25-.36.48V20.5c0 .28.22.5.5.5l.16-.03L9 18.9l6 2.1 5.64-1.9c.21-.07.36-.25.36-.48V3.5c0-.28-.22-.5-.5-.5zM15 19l-6-2.11V5l6 2.11V19z' },
        { id: 'vehicules', label: 'Véhicules', icon: 'M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.66 0-1.21.42-1.42 1.01L3 12v8c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-1h12v1c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-8l-2.08-5.99zM6.5 16c-.83 0-1.5-.67-1.5-1.5S5.67 13 6.5 13s1.5.67 1.5 1.5S7.33 16 6.5 16zm11 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zM5 11l1.5-4.5h11L19 11H5z' },
        { id: 'police', label: 'Difficulté', icon: 'M20.38 8.57l-1.23 1.85a8 8 0 01-.22 7.58H5.07A8 8 0 0115.58 6.85l1.85-1.23A10 10 0 003.35 19a2 2 0 001.72 1h13.85a2 2 0 001.74-1 10 10 0 00-.27-10.44zm-9.79 6.84a2 2 0 002.83 0l5.66-8.49-8.49 5.66a2 2 0 000 2.83z' },
        { id: 'plus', label: 'Plus', icon: 'M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 00.12-.61l-1.92-3.32a.488.488 0 00-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.484.484 0 00-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 00-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z' }
      ]
      // anciens onglets (avant la 1.4) -> nouveaux
      var OLD_TABS = { options: 'trajet', lieux: 'trajet', points: 'trajet', trafic: 'police', stats: 'plus', parametres: 'plus' }
      function normTab (t) {
        t = OLD_TABS[t] || t
        return scope.tabs.some(function (x) { return x.id === t }) ? t : 'trajet'
      }
      scope.kinds = [
        { id: 'road', label: 'Bord de route' },
        { id: 'parking', label: 'Parkings' },
        { id: 'poi', label: "Lieux d'intérêt" },
        { id: 'home', label: 'Maisons & allées' }
      ]
      scope.ui = {
        tab: normTab(saved.tab), collapsed: !!saved.collapsed,
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
        api('requestVehicles')
      }
      scope.setVeh = function (key, value) {
        scope.s.veh[key] = value
        scope.push()
        api('requestVehicles')
      }
      // police réglée pendant la livraison
      var starsTimer = null
      scope.missionPolice = function (mode) {
        $timeout.cancel(starsTimer)
        starsTimer = null
        api('setMissionPolice', mode, +scope.ui.mStars || 1)
      }
      scope.missionStars = function () {
        $timeout.cancel(starsTimer)
        starsTimer = $timeout(function () { starsTimer = null; api('setMissionPolice', 'wanted', +scope.ui.mStars || 1) }, 350)
      }
      // difficulté du temps limite (très facile -> impossible)
      var TIME_LEVELS = ['tres_facile', 'facile', 'moyen', 'dur', 'tres_dur', 'impossible']
      scope.timeLevelLabel = function (idx) {
        var list = (scope.state && scope.state.meta && scope.state.meta.timeLevels) || []
        var id = TIME_LEVELS[+(idx === undefined ? scope.ui.timeLevelIdx : idx)] || 'moyen'
        for (var i = 0; i < list.length; i++) { if (list[i].id === id) return list[i].label }
        return id
      }
      // pendant la livraison, avant le départ
      var timeLevelTimer = null
      scope.missionTimeLevel = function () {
        $timeout.cancel(timeLevelTimer)
        timeLevelTimer = $timeout(function () {
          timeLevelTimer = null
          api('setMissionTimeLevel', TIME_LEVELS[+scope.ui.mTimeIdx] || 'moyen')
        }, 100)
      }
      scope.timeLevelIdxOf = function (id) { return Math.max(0, TIME_LEVELS.indexOf(id || 'moyen')) }
      scope.setTimeLevel = function () {
        scope.s.timeLevel = TIME_LEVELS[+scope.ui.timeLevelIdx] || 'moyen'
        scope.pushSoon()
      }
      scope.setTraffic = function (key, value) {
        scope.s.traffic[key] = value
        scope.push()
      }
      scope.setAllVeh = function (group, value) {
        var list = (scope.state && scope.state.meta && scope.state.meta.categories) || []
        list.forEach(function (c) { scope.s.veh[group][c.id] = value })
        scope.push()
        api('requestVehicles')
      }

      // ---------- actions ----------
      // un curseur bougé juste avant : ses réglages partent d'abord (les commandes arrivent dans l'ordre)
      function flushPush () { if (pushPending) scope.push() }
      scope.start = function () { flushPush(); api('start') }
      scope.call = function (fn) { flushPush(); api(fn) }
      scope.callArg = function (fn, a) { flushPush(); api(fn, a) }
      scope.toggleCollapsed = function () {
        scope.ui.collapsed = !scope.ui.collapsed
        saveUi()
        if (!scope.ui.collapsed && !scope.sess) onTab(scope.ui.tab, true)
      }
      scope.setTab = function (id) {
        scope.ui.tab = id
        saveUi()
        onTab(id)
      }
      function onTab (id, auto) {
        // (l'analyse de la map ne se lance que sur le lien « Analyser la map » ou au lancement)
        if (id === 'vehicules') api('requestVehicles')
        else api('requestState')
      }

      scope.confirm = function (fn, text) { scope.ui.confirm = { fn: fn, text: text } }
      scope.doConfirm = function () {
        var c = scope.ui.confirm
        scope.ui.confirm = null
        if (c) { flushPush(); api(c.fn) }
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
        if (scope.hasTimeLeft()) return 'Temps restant' + (scope.sess && scope.sess.timeLevel ? ' · ' + scope.sess.timeLevel : '')
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
        if (!scope.sess) return ''
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
          if (!pushPending && scope.s) scope.ui.timeLevelIdx = Math.max(0, TIME_LEVELS.indexOf(scope.s.timeLevel || 'moyen'))
          if (scope.sess && scope.sess.police && !starsTimer) scope.ui.mStars = scope.sess.police.level || 1
          if (scope.sess && scope.sess.timeLevelId && !timeLevelTimer) scope.ui.mTimeIdx = Math.max(0, TIME_LEVELS.indexOf(scope.sess.timeLevelId))
          if (!scope.sess) scope.hud = {}
          if (scope.vehModels.length) scope.refreshVehView()
          if (firstState) {
            firstState = false
            var uiPrefs = data.settings && data.settings.ui
            if (uiPrefs && !Array.isArray(uiPrefs)) {
              if (uiPrefs.tab) scope.ui.tab = normTab(uiPrefs.tab)
              if (uiPrefs.collapsed !== undefined) scope.ui.collapsed = !!uiPrefs.collapsed
            }
            if (!scope.ui.collapsed && !scope.sess) onTab(scope.ui.tab, true)
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
        if (pushPending) scope.push()
        $timeout.cancel(starsTimer)
        $timeout.cancel(timeLevelTimer)
        $timeout.cancel(toastTimer)
      })

      lua("if not livraisonLibre then setExtensionUnloadMode('livraisonLibre', 'manual'); extensions.load('livraisonLibre') end; if livraisonLibre then livraisonLibre.requestState() end")
    }
  }
}])
