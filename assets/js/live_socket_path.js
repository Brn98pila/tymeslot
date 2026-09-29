/**
 * Which LiveView socket a page connects to.
 *
 * `/live` verifies the session cookie; `/embed-live` needs none, because an
 * embedded booking page authenticates with the signed embed token in its
 * LiveView session instead (mobile browsers withhold SameSite=Lax cookies
 * from cross-site iframes).
 *
 * A page the server rendered as an embed carries `data-embed-served` on
 * `<html>`, and it was sent without writing a session cookie, so it must use
 * `/embed-live` even when it is not framed: opened in its own tab it would
 * otherwise find no session on `/live` and reload for ever. Being framed
 * still picks `/embed-live` on its own, as before.
 */
export function liveSocketPath(win = window) {
  const framed = win.self !== win.top
  const servedAsEmbed = win.document.documentElement.hasAttribute("data-embed-served")

  return framed || servedAsEmbed ? "/embed-live" : "/live"
}
