(function () {
  // WithTooltip wraps buttons (e.g. the send button) with floating-ui's
  // useHover, which binds a native `mouseenter` listener on the element.
  // WebKit requires a first tap to fire that synthesized hover sequence and
  // only sends `click` on a second tap. Registering any touchstart listener
  // switches WebKit's touch-to-mouse-event heuristic so click fires on the
  // first tap instead.
  document.addEventListener('touchstart', function () {}, { passive: true })

  var TARGET_HREF_PREFIX = 'https://mattermost.com/community/'
  var NEW_HREF = 'https://github.com/ForwardAlliance/fa-mattermost'
  var NEW_TEXT = 'github.com/ForwardAlliance/fa-mattermost'
  var NEW_LABEL = '原始碼：'

  function patchAboutLink() {
    document.querySelectorAll('.about-modal__footer a').forEach(function (link) {
      if (link.href.indexOf(TARGET_HREF_PREFIX) !== 0) return
      link.href = NEW_HREF
      link.textContent = NEW_TEXT
      var labelNode = link.previousSibling
      if (labelNode) {
        labelNode.textContent = NEW_LABEL
      }
    })
  }

  new MutationObserver(patchAboutLink).observe(document.body, { childList: true, subtree: true })
})()
