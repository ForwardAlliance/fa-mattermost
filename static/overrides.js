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
