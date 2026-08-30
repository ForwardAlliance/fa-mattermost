(function () {
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
