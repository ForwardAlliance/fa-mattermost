;(function () {
  // Neutralizes WebKit's generic 300ms tap-delay / double-tap-to-zoom
  // detection window. This does NOT fix the WithTooltip double-tap issue
  // below — that's a separate WebKit quirk tied to elements that have their
  // own real `mouseenter` listener, unaffected by whether anything else on
  // the page listens for touch.
  document.addEventListener('touchstart', function () {}, { passive: true })

  var TARGET_HREF_PREFIX = 'https://mattermost.com/community/'
  var NEW_HREF = 'https://github.com/ForwardAlliance/fa-mattermost'
  var NEW_TEXT = 'github.com/ForwardAlliance/fa-mattermost'
  var NEW_LABEL = '原始碼：'

  function patchAboutLink() {
    document
      .querySelectorAll('.about-modal__footer a')
      .forEach(function (link) {
        if (link.href.indexOf(TARGET_HREF_PREFIX) !== 0) return
        link.href = NEW_HREF
        link.textContent = NEW_TEXT
        var labelNode = link.previousSibling
        if (labelNode) {
          labelNode.textContent = NEW_LABEL
        }
      })
  }

  new MutationObserver(patchAboutLink).observe(document.body, {
    childList: true,
    subtree: true,
  })
})()

// WithTooltip wraps most icon buttons (send, emoji picker, reply, pin, ...)
// with floating-ui's useHover, which binds a real `mouseenter`/`mousemove`
// listener directly on the button, bypassing React's event delegation. On
// iOS Safari, tapping such a button fires a synthesized `mouseenter` first
// (opening the tooltip) and only sends `click` on a second, separate tap.
// This drives the click straight from `touchend` instead, so a single tap
// performs the action regardless of the tooltip's hover state, while
// suppressing any native click that still follows so the action can't fire
// twice.
;(function () {
  var TAP_TARGET_SELECTOR = 'button, [role="button"], a'
  var TAP_MOVE_THRESHOLD = 10
  var TAP_MAX_DURATION = 500
  var DUPLICATE_CLICK_WINDOW = 500

  var touchStart = null
  var lastSyntheticTarget = null
  var lastSyntheticTime = 0

  document.addEventListener(
    'touchstart',
    function (event) {
      touchStart = null
      if (event.touches.length !== 1) return

      var target = event.target.closest
        ? event.target.closest(TAP_TARGET_SELECTOR)
        : null
      if (!target) return

      var touch = event.touches[0]
      touchStart = {
        target: target,
        x: touch.clientX,
        y: touch.clientY,
        time: Date.now(),
      }
    },
    { passive: true },
  )

  document.addEventListener(
    'touchend',
    function (event) {
      var start = touchStart
      touchStart = null
      if (!start || start.target.disabled) return

      var touch = event.changedTouches[0]
      if (!touch) return

      var dx = touch.clientX - start.x
      var dy = touch.clientY - start.y
      if (Math.sqrt(dx * dx + dy * dy) > TAP_MOVE_THRESHOLD) return
      if (Date.now() - start.time > TAP_MAX_DURATION) return

      var target = event.target.closest
        ? event.target.closest(TAP_TARGET_SELECTOR)
        : null
      if (target !== start.target) return

      lastSyntheticTarget = target
      lastSyntheticTime = Date.now()

      var syntheticClick = new MouseEvent('click', {
        bubbles: true,
        cancelable: true,
        view: window,
      })
      syntheticClick.__isSyntheticTap = true
      target.dispatchEvent(syntheticClick)
    },
    { passive: true },
  )

  document.addEventListener(
    'click',
    function (event) {
      if (event.__isSyntheticTap) return
      if (Date.now() - lastSyntheticTime >= DUPLICATE_CLICK_WINDOW) return

      var target = event.target.closest
        ? event.target.closest(TAP_TARGET_SELECTOR)
        : null
      if (target === lastSyntheticTarget) {
        lastSyntheticTarget = null
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    },
    true,
  )
})()

// Volunteers never hold a Mattermost password: the account service signs them
// in, so the login form is a dead end for them. Whenever Mattermost shows it
// (a direct visit, an expired session, or a logout, which reaches /login by
// client-side navigation), this sends them through the account service's
// /mattermost/go instead. That URL differs per environment and is already the
// "Forgot password" link, so it is read from the public client config rather
// than written here. System admins reach the form with /login?admin=1.
;(function () {
  var ACCOUNT_SIGN_IN_SUFFIX = '/mattermost/go'
  var LAST_REDIRECT_KEY = 'fa:loginRedirectAt'
  // A sign-in that Mattermost still rejects would otherwise bounce forever.
  var REDIRECT_COOLDOWN = 10000

  var redirecting = false

  function readLastRedirect() {
    try {
      return Number(window.sessionStorage.getItem(LAST_REDIRECT_KEY)) || 0
    } catch (error) {
      return 0
    }
  }

  function writeLastRedirect(time) {
    try {
      window.sessionStorage.setItem(LAST_REDIRECT_KEY, String(time))
    } catch (error) {}
  }

  // Resolved rather than pattern-matched: the URL parser turns `//host`,
  // `/\host` and paths with embedded tabs or newlines into other origins.
  function safeRedirectPath(params) {
    var origin = window.location.origin
    try {
      var target = new URL(params.get('redirect_to') || '/', origin)
      return target.origin === origin
        ? target.pathname + target.search + target.hash
        : '/'
    } catch (error) {
      return '/'
    }
  }

  function isVolunteerLoginPage(params) {
    return (
      window.location.pathname.indexOf('/login') === 0 &&
      params.get('admin') !== '1'
    )
  }

  function redirectFromLogin() {
    var params = new URLSearchParams(window.location.search)
    var now = Date.now()

    if (redirecting || !isVolunteerLoginPage(params)) return
    if (now - readLastRedirect() < REDIRECT_COOLDOWN) return

    redirecting = true

    fetch('/api/v4/config/client?format=old', { credentials: 'same-origin' })
      .then(function (response) {
        return response.ok ? response.json() : {}
      })
      .then(function (config) {
        var link = config.ForgotPasswordLink
        if (!link) return

        var target = new URL(link)
        if (
          target.pathname.slice(-ACCOUNT_SIGN_IN_SUFFIX.length) !==
          ACCOUNT_SIGN_IN_SUFFIX
        ) {
          return
        }

        target.searchParams.set('p', safeRedirectPath(params))
        writeLastRedirect(now)
        window.location.replace(target.toString())
      })
      .catch(function () {})
      .then(function () {
        redirecting = false
      })
  }

  redirectFromLogin()
  new MutationObserver(redirectFromLogin).observe(document.body, {
    childList: true,
    subtree: true,
  })
})()
