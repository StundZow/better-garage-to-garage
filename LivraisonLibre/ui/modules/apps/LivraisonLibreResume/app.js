angular.module('beamng.apps')
.directive('livraisonLibreResume', ['$filter', '$timeout', '$interval', function ($filter, $timeout, $interval) {
  return {
    templateUrl: '/ui/modules/apps/LivraisonLibreResume/app.html',
    replace: false,
    restrict: 'E',
    scope: true,
    link: function (scope) {
      var tick = null
      var hideTimer = null
      var translate
      try { translate = $filter('translate') } catch (e) { translate = function (s) { return s } }

      scope.visible = false
      scope.leaving = false
      scope.live = {on: false, stars: 0, timeLeft: null}
      scope.fmtClock = function (sec) {
        sec = Math.max(0, Math.ceil(+sec || 0))
        var m = Math.floor(sec / 60), s = sec % 60
        return m + ':' + (s < 10 ? '0' : '') + s
      }
      var liveTimer = null
      scope.sum = null
      scope.progress = 1

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
      scope.tr = function (s) {
        if (typeof s !== 'string') return s
        if (/^[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)+$/.test(s)) {
          var t = translate(s)
          if (t && t !== s) return t
        }
        return s
      }
      scope.fmtInt = function (v) {
        return String(Math.round(+v || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')
      }
      scope.hasRecords = function () {
        var r = scope.sum && scope.sum.records
        return !!(r && (r.avg || r.fastest || r.longest))
      }

      function stop () {
        if (tick) { $interval.cancel(tick); tick = null }
        if (hideTimer) { $timeout.cancel(hideTimer); hideTimer = null }
      }

      function show (data) {
        stop()
        if (data && Array.isArray(data.records)) data.records = {}
        scope.sum = data
        scope.visible = true
        scope.leaving = false
        scope.progress = 1
        var duration = Math.max(1, +(data && data.showFor) || 5) * 1000
        var start = Date.now()
        tick = $interval(function () {
          var t = (Date.now() - start) / duration
          scope.progress = Math.max(0, 1 - t)
          if (t >= 1) {
            stop()
            scope.leaving = true
            hideTimer = $timeout(function () { scope.visible = false; scope.leaving = false }, 400)
          }
        }, 100)
      }

      // étoiles en direct : le HUD du mod est envoyé toutes les 0,2 s pendant une session de livraisons
      scope.$on('LivraisonLibreHud', function (event, data) {
        scope.$evalAsync(function () {
          if (!data || !data.phase) return
          scope.live.on = true
          scope.live.stars = Math.max(0, Math.min(5, Math.round(+data.stars || 0)))
          scope.live.timeLeft = (data.phase === 'driving' && typeof data.timeLeft === 'number') ? data.timeLeft : null
          if (liveTimer) $timeout.cancel(liveTimer)
          liveTimer = $timeout(function () { scope.live.on = false; scope.live.stars = 0; scope.live.timeLeft = null }, 1500) // plus de HUD = session arrêtée
        })
      })
      scope.$on('LivraisonLibreState', function (event, data) {
        scope.$evalAsync(function () {
          if (data && !data.session) { scope.live.on = false; scope.live.stars = 0; scope.live.timeLeft = null }
        })
      })

      scope.$on('LivraisonLibreSummary', function (event, data) {
        scope.$evalAsync(function () { show(data || {}) })
      })
      scope.$on('$destroy', function () {
        stop()
        if (liveTimer) $timeout.cancel(liveTimer)
      })
    }
  }
}])
