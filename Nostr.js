.pragma library

// Pure helpers for the Nostr bar plugin: NIP-19 npub decoding, notification
// categorization, profile parsing, and display formatting. No QML types here;
// everything is plain JS so the panel and the client can share it cheaply.

var CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

var BOOTSTRAP_RELAYS = [
  "wss://relay.damus.io",
  "wss://nos.lol",
  "wss://purplepag.es",
  "wss://relay.primal.net"
]

var FALLBACK_RELAYS = [
  "wss://relay.damus.io",
  "wss://nos.lol",
  "wss://relay.primal.net"
]

function bootstrapRelays() { return BOOTSTRAP_RELAYS.slice() }
function fallbackRelays() { return FALLBACK_RELAYS.slice() }

function polymod(values) {
  var GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
  var chk = 1
  for (var i = 0; i < values.length; i++) {
    var top = chk >> 25
    chk = ((chk & 0x1ffffff) << 5) ^ values[i]
    for (var j = 0; j < 5; j++) {
      chk ^= ((top >> j) & 1) === 0 ? 0 : GEN[j]
    }
  }
  return chk >>> 0
}

function hrpExpand(hrp) {
  var out = []
  for (var i = 0; i < hrp.length; i++) out.push(hrp.charCodeAt(i) >> 5)
  out.push(0)
  for (var k = 0; k < hrp.length; k++) out.push(hrp.charCodeAt(k) & 31)
  return out
}

function convertBits(data, fromBits, toBits, pad) {
  var acc = 0
  var bits = 0
  var out = []
  var maxv = (1 << toBits) - 1
  for (var i = 0; i < data.length; i++) {
    var value = data[i]
    if (value < 0 || value >> fromBits !== 0) return null
    acc = (acc << fromBits) | value
    bits += fromBits
    while (bits >= toBits) {
      bits -= toBits
      out.push((acc >> bits) & maxv)
    }
  }
  if (pad) {
    if (bits > 0) out.push((acc << (toBits - bits)) & maxv)
  } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) !== 0) {
    return null
  }
  return out
}

// npub1... -> 64-char lowercase hex, or "" when the input is not a valid npub.
function npubToHex(npub) {
  var s = String(npub || "").trim().toLowerCase()
  var pos = s.lastIndexOf("1")
  if (pos < 1 || pos + 7 > s.length || s.length > 200) return ""
  var hrp = s.substring(0, pos)
  if (hrp !== "npub") return ""
  var data = []
  for (var i = pos + 1; i < s.length; i++) {
    var idx = CHARSET.indexOf(s.charAt(i))
    if (idx === -1) return ""
    data.push(idx)
  }
  if (polymod(hrpExpand(hrp).concat(data)) !== 1) return ""
  var bytes = convertBits(data.slice(0, -6), 5, 8, false)
  if (!bytes || bytes.length !== 32) return ""
  var hex = ""
  for (var b = 0; b < bytes.length; b++) {
    hex += ("0" + bytes[b].toString(16)).slice(-2)
  }
  return hex
}

function createChecksum(hrp, data) {
  var values = hrpExpand(hrp).concat(data).concat([0, 0, 0, 0, 0, 0])
  var mod = polymod(values) ^ 1
  var out = []
  for (var i = 0; i < 6; i++) out.push((mod >> (5 * (5 - i))) & 31)
  return out
}

function hexToBytes(h) {
  var out = []
  for (var i = 0; i < h.length; i += 2) out.push(parseInt(h.substring(i, i + 2), 16))
  return out
}

function bech32Encode(hrp, data5) {
  var checksum = createChecksum(hrp, data5)
  var s = hrp + "1"
  for (var c = 0; c < data5.length; c++) s += CHARSET.charAt(data5[c])
  for (var k = 0; k < checksum.length; k++) s += CHARSET.charAt(checksum[k])
  return s
}

// 64-char hex -> npub1... (best effort; returns "" on malformed hex).
function hexToNpub(hex) {
  var h = String(hex || "").toLowerCase()
  if (!/^[0-9a-f]{64}$/.test(h)) return ""
  var data = convertBits(hexToBytes(h), 8, 5, true)
  if (!data) return ""
  return bech32Encode("npub", data)
}

// NIP-19 nevent1: TLV entries - type 0 special (the event id), type 1 relay
// hints, type 2 author, type 3 kind. The id must be a TLV entry, not raw
// bytes: clients skip unknown types, so a missing 0x00 0x20 header makes the
// event unresolvable.
function nevent(idHex, opts) {
  var id = String(idHex || "").toLowerCase()
  if (!/^[0-9a-f]{64}$/.test(id)) return ""
  var bytes = [0, 32].concat(hexToBytes(id))
  var o = opts || {}
  var relays = o.relays || []
  for (var r = 0; r < relays.length && r < 3; r++) {
    var url = String(relays[r])
    if (url.indexOf("wss://") !== 0) continue
    bytes.push(1, url.length)
    for (var u = 0; u < url.length; u++) bytes.push(url.charCodeAt(u) & 0xff)
  }
  if (typeof o.authorHex === "string" && /^[0-9a-f]{64}$/i.test(o.authorHex)) {
    bytes.push(2, 32)
    bytes = bytes.concat(hexToBytes(o.authorHex.toLowerCase()))
  }
  if (o.kind !== undefined && o.kind !== null) {
    var k = o.kind >>> 0
    bytes.push(3, 4, (k >> 24) & 255, (k >> 16) & 255, (k >> 8) & 255, k & 255)
  }
  var data = convertBits(bytes, 8, 5, true)
  if (!data) return ""
  return bech32Encode("nevent", data)
}

// Client deep-link routes (verified: primal.net, jumble.social,
// coracle.social, nostrich.org all serve /e/<nevent1|note1|hex>).
var CLIENTS = {
  primal: { label: "Primal", base: "https://primal.net/e/" },
  jumble: { label: "Jumble", base: "https://jumble.social/notes/" },
  coracle: { label: "Coracle", base: "https://coracle.social/notes/" },
  nostrich: { label: "Nostrich", base: "https://nostrich.org/e/" }
}

function clientOptions() {
  return [
    { label: "Primal", value: "primal" },
    { label: "Jumble", value: "jumble" },
    { label: "Coracle", value: "coracle" },
    { label: "Nostrich", value: "nostrich" }
  ]
}

function isValidClientName(name) {
  return Object.prototype.hasOwnProperty.call(CLIENTS, name)
}

function eventUrl(clientName, idHex, opts) {
  var client = CLIENTS[clientName] || CLIENTS.primal
  var id = nevent(idHex, opts)
  if (id === "") return ""
  return client.base + id
}

// Read relays (NIP-01 kind 10002) - tag ["r", url, marker?]; marker read or absent.
function readRelaysFromEvent(ev) {
  var out = []
  var tags = ev && ev.tags ? ev.tags : []
  for (var i = 0; i < tags.length; i++) {
    var t = tags[i]
    if (t && t[0] === "r" && typeof t[1] === "string" && t[1].indexOf("wss://") === 0) {
      var marker = t.length > 2 ? t[2] : ""
      if (marker === "" || marker === "read") {
        if (out.indexOf(t[1]) === -1) out.push(t[1])
      }
    }
  }
  return out
}

function tagValue(tags, key) {
  for (var i = 0; i < tags.length; i++) {
    if (tags[i] && tags[i][0] === key && typeof tags[i][1] === "string") return tags[i][1]
  }
  return ""
}

function hasTag(tags, key) {
  for (var i = 0; i < tags.length; i++) {
    if (tags[i] && tags[i][0] === key) return true
  }
  return false
}

// Kind 10002 arrives on the resolve subscription; everything else is feed noise.
function isMyRelayList(ev, myHex) {
  return ev && ev.kind === 10002 && ev.pubkey === myHex
}

// Bolt11 amount -> sats. Returns 0 when unparseable.
function bolt11Sats(bolt11) {
  var m = /^lnbc(\d+)(m|u|n|p)?1/i.exec(String(bolt11 || ""))
  if (!m) return 0
  var amount = parseInt(m[1], 10)
  var unit = (m[2] || "").toLowerCase()
  if (unit === "m") return Math.round(amount * 100000)
  if (unit === "u") return Math.round(amount * 100)
  if (unit === "n") return Math.round(amount / 10)
  if (unit === "p") return Math.round(amount / 10000)
  return amount * 100000000
}

function zapSenderHex(ev) {
  // NIP-57: the zap receipt is published by the receiver's LNURL node; the
  // human sender lives in the embedded kind 9734 request in `content`.
  try {
    var inner = JSON.parse(ev.content)
    if (inner && typeof inner.pubkey === "string" && /^[0-9a-f]{64}$/i.test(inner.pubkey)) {
      return inner.pubkey.toLowerCase()
    }
  } catch (e) {}
  return ev.pubkey
}

function zapMessage(ev) {
  try {
    var inner = JSON.parse(ev.content)
    if (inner && typeof inner.content === "string" && inner.content.trim() !== "") {
      return truncateText(inner.content, 160)
    }
  } catch (e) {}
  return ""
}

// Reactions carry meaning in their literal content: "+" and "-" are protocol
// shorthands, anything else (custom emoji, words) is shown as the author typed
// it.
function reactionDisplay(content) {
  var c = String(content || "").replace(/\s+/g, " ").trim()
  if (c === "" || c === "+") return "❤️"
  if (c === "-") return "🚫"
  if (c.length > 24) c = c.substring(0, 24) + "…"
  return c
}

function eventIdTag(tags) {
  var upper = ""
  for (var i = 0; i < tags.length; i++) {
    var t = tags[i]
    if (!t || typeof t[1] !== "string" || !/^[0-9a-f]{64}$/i.test(t[1])) continue
    if (t[0] === "e") return t[1].toLowerCase()
    // NIP-22 points at the parent with lowercase e; top-level comments on
    // non-note content may only carry the uppercase root E, which doubles
    // as the context link.
    if (t[0] === "E" && upper === "") upper = t[1].toLowerCase()
  }
  return upper
}

// First http(s) media URL in a note body (client links usually carry a file
// extension). Returns { type: "image"|"video", url } or null.
function firstMediaUrl(content) {
  var urls = String(content || "").match(/https?:\/\/[^\s<>"')\]]+/g) || []
  for (var i = 0; i < urls.length; i++) {
    var u = urls[i].replace(/[).,;:!?]+$/, "")
    if (/\.(png|jpe?g|gif|webp|avif|bmp)(\?|#|$)/i.test(u)) return { type: "image", url: u }
    if (/\.(mp4|webm|m4v|mov)(\?|#|$)/i.test(u)) return { type: "video", url: u }
  }
  return null
}

function stripMediaUrl(content, url) {
  return String(content || "").replace(url, " ").replace(/\s+/g, " ").trim()
}

// Build the row model for a feed event, or null when it should be ignored.
function notificationFromEvent(ev, myHex) {
  if (!ev || typeof ev.id !== "string") return null
  var tags = ev.tags || []
  var type = notificationType(ev, myHex)
  if (type === "") return null

  var author = ev.pubkey
  var detail = ""
  var media = type === "zap" ? null : firstMediaUrl(ev.content)
  if (type === "zap") {
    author = zapSenderHex(ev)
    var sats = bolt11Sats(tagValue(tags, "bolt11"))
    var msg = zapMessage(ev)
    detail = (sats > 0 ? formatSats(sats) : "Zap") + (msg ? " · “" + msg + "”" : "")
  } else if (type === "reaction") {
    detail = media ? "" : reactionDisplay(ev.content)
  } else if (type === "repost") {
    // The quoted parent note (fetched via the e tag) is the useful detail.
    detail = ""
  } else {
    media = firstMediaUrl(ev.content)
    detail = truncateText(media ? stripMediaUrl(ev.content, media.url) : ev.content, 160)
  }

  return {
    id: ev.id,
    type: type,
    kind: Number(ev.kind) || 0,
    author: author.toLowerCase(),
    created: Number(ev.created_at) || 0,
    detail: detail,
    media: media,
    refId: eventIdTag(tags)
  }
}

// Quoted parent note for a reaction/repost/zap/reply row, rendered from the
// fetched parent event (shown in italics). "" until the parent is known.
function contextText(fetchedEvent, myHex, myName) {
  if (!fetchedEvent || typeof fetchedEvent.content !== "string") return ""
  var body = truncateText(fetchedEvent.content, 110)
  return body === "" ? "" : body
}

function stripNostrRefs(text) {
  var t = String(text || "")
  t = t.replace(/nostr:(npub|nprofile|note|nevent)1[02-9ac-z]+/gi, "@nostr")
  t = t.replace(/\b(npub|note)1[02-9ac-z]+\b/gi, "@nostr")
  t = t.replace(/\[\[([^\]]*)\]\]/g, "$1")
  t = t.replace(/\[(https?:\/\/[^\]]+)\]\((https?:\/\/[^)]+)\)/g, "$2")
  t = t.replace(/^(https?:\/\/\S+\s*\n)+/g, "")
  t = t.replace(/\s+/g, " ").trim()
  return t
}

function truncateText(text, max) {
  var t = stripNostrRefs(text)
  var limit = max || 160
  if (t.length > limit) t = t.substring(0, limit).trim() + "…"
  return t
}

// Kind -> notification type, or "" for events that are not notifications.
// NIP-51 mute list (kind 10000): public `p` tags are muted pubkeys.
// Encrypted private mutes in `content` are unreadable to a read-only
// client, so only the public list applies.
function muteListAuthors(ev) {
  var out = []
  var tags = ev && ev.tags ? ev.tags : []
  for (var i = 0; i < tags.length; i++) {
    var t = tags[i]
    if (t && t[0] === "p" && typeof t[1] === "string" && /^[0-9a-f]{64}$/i.test(t[1])) {
      var h = t[1].toLowerCase()
      if (out.indexOf(h) === -1) out.push(h)
    }
  }
  return out
}

function notificationType(ev, myHex) {
  var kind = ev.kind
  if (kind === 9735) return "zap"
  if (kind === 6) return "repost"
  if (kind === 7) return "reaction"
  if (kind === 1) {
    return hasTag(ev.tags || [], "e") ? "reply" : "mention"
  }
  // NIP-22 comments: lowercase e is the parent item, uppercase E the root
  // scope (may be all a top-level comment on non-note content carries).
  if (kind === 1111) {
    return hasTag(ev.tags || [], "e") || hasTag(ev.tags || [], "E") ? "reply" : "mention"
  }
  return ""
}

function parseProfile(content) {
  var out = { name: "", displayName: "", picture: "", about: "" }
  try {
    var meta = JSON.parse(content)
    if (!meta || typeof meta !== "object") return out
    out.name = typeof meta.name === "string" ? meta.name : ""
    out.displayName = typeof meta.display_name === "string" && meta.display_name !== "" ? meta.display_name : out.name
    out.picture = typeof meta.picture === "string" && meta.picture.indexOf("http") === 0 ? meta.picture : ""
    out.about = typeof meta.about === "string" ? meta.about : ""
  } catch (e) {}
  return out
}

function profileLabel(profile, authorHex) {
  if (profile && profile.displayName !== "") return profile.displayName
  if (profile && profile.name !== "") return profile.name
  return shortHex(authorHex)
}

function shortHex(hex) {
  var h = String(hex || "")
  if (h.length <= 12) return h
  return h.substring(0, 6) + "…" + h.substring(h.length - 4)
}

function formatSats(sats) {
  var n = Math.round(Number(sats) || 0)
  if (n >= 1000000) return (n / 1000000).toFixed(n % 1000000 === 0 ? 0 : 1) + "M sats"
  if (n >= 1000) return n.toLocaleString() + " sats"
  return n + (n === 1 ? " sat" : " sats")
}

function timeAgo(created, nowSec) {
  var delta = Math.max(0, (Number(nowSec) || 0) - (Number(created) || 0))
  if (delta < 60) return "now"
  if (delta < 3600) return Math.floor(delta / 60) + "m ago"
  if (delta < 86400) return Math.floor(delta / 3600) + "h ago"
  if (delta < 7 * 86400) return Math.floor(delta / 86400) + "d ago"
  return Math.floor(delta / (7 * 86400)) + "w ago"
}

function nowSec() {
  return Math.floor(Date.now() / 1000)
}
