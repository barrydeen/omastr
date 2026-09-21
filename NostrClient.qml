import QtQuick
import Quickshell
import Quickshell.Io
import "Nostr.js" as Nostr

// Feed engine for the Nostr bar plugin. Owns the persisted identity + client
// preference (~/.local/state/omarchy/settings/nostr-notifications.json), the
// relay connections (Relay.qml delegates mounted by Panel.qml's Repeater), the
// categorized notification list, the kind-0 profile / parent-event side
// fetches, and the desktop-notification fan-out. Visual-free; Panel.qml and
// BarWidget.qml only read its properties.
Item {
  id: root

  property string npub: ""
  property string pubkey: ""              // hex
  property string clientName: "primal"    // deep-link target for clicks
  property var relays: []                 // read (inbox) relays: feed lives here
  property var writeRelays: []            // write (outbox) relays: mutes live here
  property var allRelays: []              // union; what we keep connected to
  property bool resolving: false          // kind 10002 lookup in flight
  property bool refreshingRelays: false   // background kind 10002 refresh;
                                          // feed stays live meanwhile
  property int relayListAt: 0             // created_at of the applied list
  property var bestRelayList: null        // newest kind 10002 seen in the
                                          // current resolve window
  property int pendingOutbox: 0           // relays asked for 10002 that have
                                          // not sent EOSE yet
  property bool synced: false             // feed caught up with history
  property string error: ""
  property int lastRead: 0
  property var notifications: []          // row models, newest first
  property var profiles: ({})             // author hex -> parsed kind 0
  property var fetchedEvents: ({})        // parent event id -> {author, kind, content}
  property int unreadCount: 0

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/nostr-notifications.json"
  readonly property string avatarDir: Quickshell.env("HOME") + "/.cache/omarchy/nostr/avatars"

  readonly property string subOutbox: "omn_outbox"
  readonly property string subFeed: "omn_feed"
  readonly property string subMutes: "omn_mutes"
  readonly property string subProfiles: "omn_profiles"
  readonly property string subEvents: "omn_events"

  property int socketCount: 0

  property var sockets: []
  property var seen: ({})
  property var mutedAuthors: ({})     // union of NIP-51 kind 10000 `p` tags, lowercase hex
  property var mutedByRelay: ({})     // relay url -> [hex], so one relay's
                                      // stale/empty list can't wipe another's
  // Local blocklist (npub/hex added in settings): guaranteed to apply even
  // when mutes only exist as encrypted private list items, which a
  // read-only client cannot decrypt.
  property var blockedAuthors: []
  property var wantedAuthors: ({})
  property var wantedEvents: ({})
  property var pendingNotify: []          // rows waiting for profiles before desktop ping

  // Event kinds the user wants surfaced (reply/mention = kind 1, repost = 6,
  // reaction = 7, zap = 9735). Editable from the settings view.
  property var enabledTypes: ["reply", "mention", "repost", "reaction", "zap"]
  readonly property var typeGroups: ({
    replies: ["reply", "mention"],
    reposts: ["repost"],
    reactions: ["reaction"],
    zaps: ["zap"]
  })

  function typeEnabled(type) {
    return root.enabledTypes.indexOf(type) !== -1
  }

  function isGroupEnabled(group) {
    var items = root.typeGroups[group]
    if (!items) return false
    for (var i = 0; i < items.length; i++)
      if (root.enabledTypes.indexOf(items[i]) === -1) return false
    return true
  }

  function setGroupEnabled(group, on) {
    var items = root.typeGroups[group]
    if (!items) return
    var list = root.enabledTypes.slice()
    for (var i = 0; i < items.length; i++) {
      var idx = list.indexOf(items[i])
      if (on && idx === -1) list.push(items[i])
      if (!on && idx !== -1) list.splice(idx, 1)
    }
    root.enabledTypes = list
    root.saveState()

    // Drop hidden rows, un-forget them so re-enabling can re-pull them.
    var kept = []
    for (var j = 0; j < root.notifications.length; j++) {
      var n = root.notifications[j]
      if (root.typeEnabled(n.type)) kept.push(n)
      else root.seen[n.id] = false
    }
    root.notifications = kept
    updateUnread()

    if (!root.resolving) root.resubscribe()
  }

  // ---------- Persistence ----------

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    onLoadFailed: {}
  }

  function applyState(text) {
    var st = null
    try { st = JSON.parse(text) } catch (e) {}
    if (!st || typeof st !== "object") return
    if (Nostr.isValidClientName(st.clientName || "")) root.clientName = st.clientName
    if (Array.isArray(st.types) && st.types.length > 0) {
      var all = ["reply", "mention", "repost", "reaction", "zap"]
      var ts = st.types.filter(function (t) { return all.indexOf(t) !== -1 })
      if (ts.length > 0) root.enabledTypes = ts
    }
    if (Array.isArray(st.blocked)) {
      root.blockedAuthors = st.blocked.filter(function (h) {
        return typeof h === "string" && /^[0-9a-f]{64}$/.test(h)
      }).map(function (h) { return h.toLowerCase() })
    } else {
      // No stored list yet: seed with the locally reported block.
      root.blockedAuthors = ["d7100f9e3079cb803be226e198269bf9aa8d1e7576d7fbe27a009a3a1780be22"]
    }
    var hex = Nostr.npubToHex(st.npub || "")
    if (hex === "" || hex === root.pubkey) return
    root.npub = Nostr.hexToNpub(hex)
    root.pubkey = hex
    root.wantProfile(hex)
    var r = Array.isArray(st.relays) ? st.relays.filter(function (u) { return typeof u === "string" && u.indexOf("wss://") === 0 }) : []
    root.relays = r.length > 0 ? r : Nostr.fallbackRelays()
    var w = Array.isArray(st.writeRelays) ? st.writeRelays.filter(function (u) { return typeof u === "string" && u.indexOf("wss://") === 0 }) : []
    root.writeRelays = w.length > 0 ? w : root.relays.slice()
    // Stored lists may predate the read/write split (or have gone stale):
    // keep the feed live on stored relays while re-resolving kind 10002
    // on bootstrap relays in the background.
    root.refreshingRelays = true
    // The connection set is the union of read, write and indexer relays - the
    // same one updateConnectionUrls() builds. Assembling it by hand here left
    // the write relays out, so the mute subscription had no socket at startup
    // (upstream only got it right by accident, when the first indexer answer
    // was applied on top).
    root.updateConnectionUrls()
    root.lastRead = Number(st.lastRead) || 0
    // Remember when the stored list was published, so a stale copy served by
    // an indexer at startup cannot replace a newer list we already applied.
    root.relayListAt = Number(st.relayListAt) || 0
    resolveTimer.restart()
  }

  Process {
    id: saveProc
  }

  function saveState() {
    var payload = JSON.stringify({
      npub: root.npub,
      relays: root.relays,
      writeRelays: root.writeRelays,
      relayListAt: root.relayListAt,
      lastRead: root.lastRead,
      clientName: root.clientName,
      types: root.enabledTypes,
      blocked: root.blockedAuthors
    }, null, 2)
    saveProc.command = ["bash", "-c",
      "mkdir -p \"$HOME/.local/state/omarchy/settings\" && printf '%s' \"$1\" > \"$HOME/.local/state/omarchy/settings/nostr-notifications.json\"",
      "nostr-state", payload]
    if (saveProc.running) saveProc.running = false
    saveProc.running = true
  }

  function setClientName(name) {
    if (!Nostr.isValidClientName(name)) return
    root.clientName = name
    root.saveState()
  }

  // ---------- Identity + relay discovery ----------

  // configure(npubString): validate, resolve the author's relay list, connect.
  function configure(input) {
    var hex = Nostr.npubToHex(input || "")
    if (hex === "") {
      root.error = "That doesn't look like a valid npub"
      return
    }
    root.error = ""
    root.npub = Nostr.hexToNpub(hex)
    root.pubkey = hex
    root.notifications = []
    root.profiles = ({})
    root.fetchedEvents = ({})
    root.seen = ({})
    root.wantedAuthors = ({})
    root.wantedEvents = ({})
    root.pendingNotify = []
    // Our own kind-0 drives the footer identity.
    root.wantProfile(hex)
    root.synced = false
    root.resolving = true
    root.refreshingRelays = false
    // A different identity starts its own resolve window: nothing from the
    // previous key may be applied to this one.
    root.bestRelayList = null
    root.relayListAt = 0
    root.pendingOutbox = 0
    root.relays = Nostr.bootstrapRelays()
    root.writeRelays = []
    root.updateConnectionUrls()
    root.saveState()
    resolveTimer.restart()
  }

  function disconnectIdentity() {
    root.npub = ""
    root.pubkey = ""
    root.relays = []
    root.writeRelays = []
    root.updateConnectionUrls()
    root.notifications = []
    root.profiles = ({})
    root.fetchedEvents = ({})
    root.seen = ({})
    root.pendingNotify = []
    root.synced = false
    root.resolving = false
    root.refreshingRelays = false
    root.bestRelayList = null
    root.relayListAt = 0
    root.pendingOutbox = 0
    root.error = ""
    root.saveState()
  }

  // Kind 10002 is a replaceable event: the newest created_at wins, not the
  // first relay to answer. Which relay answers first is luck, and an indexer
  // can still be serving the list from before the last publish, so hold the
  // newest answer and apply it when the resolve window closes.
  function collectRelayList(ev) {
    var created = Number(ev.created_at) || 0
    if (root.bestRelayList === null || created > root.bestRelayList.created) {
      var r = Nostr.readRelaysFromEvent(ev)
      var w = Nostr.readWriteRelaysFromEvent(ev)
      root.bestRelayList = {
        created: created,
        relays: r.length > 0 ? r : Nostr.fallbackRelays(),
        writeRelays: w.length > 0 ? w : Nostr.fallbackRelays()
      }
    }
    // An answer inside the window is applied on close; one arriving after it
    // is a live list change and replaces the applied list straight away.
    if (root.resolving || root.refreshingRelays) return
    if (root.bestRelayList.created > root.relayListAt) root.applyRelayList(root.bestRelayList, false)
  }

  function applyRelayList(list, wasResolving) {
    root.relayListAt = list.created
    root.resolving = false
    root.refreshingRelays = false
    root.relays = list.relays
    root.writeRelays = list.writeRelays
    root.updateConnectionUrls()
    root.saveState()
    // Foreground setup resolves before any subscription exists; a
    // background refresh must re-subscribe existing sockets so role
    // changes (new write relays) take effect.
    if (!wasResolving) root.resubscribe()
  }

  // Close the resolve window: apply the newest list seen, or fall back to
  // well-known relays when no relay answered at all.
  function finishRelayLookup() {
    if (!root.resolving && !root.refreshingRelays) return
    var wasResolving = root.resolving
    root.resolving = false
    root.refreshingRelays = false
    root.pendingOutbox = 0
    if (root.bestRelayList !== null && root.bestRelayList.created > root.relayListAt) {
      root.applyRelayList(root.bestRelayList, wasResolving)
      return
    }
    // Nothing newer than what is already applied: a background refresh must
    // leave both lists exactly as they are. Mirroring the reads into the
    // writes here - as the deadline handler does when nothing answered at all -
    // would drop the outbox relays, and with them the mute list, on every
    // session where the indexers simply confirm the list we already have.
    if (!wasResolving) return
    root.relays = Nostr.fallbackRelays()
    root.writeRelays = Nostr.fallbackRelays()
    root.updateConnectionUrls()
    root.saveState()
  }

  // The deadline, and the fallback when no relay list arrives: the window
  // normally closes on EOSE, this catches a relay that never answers.
  Timer {
    id: resolveTimer
    interval: 8000
    onTriggered: root.finishRelayLookup()
  }

  // Union of read + write + bootstrap relays; drives the Relay delegates. Read
  // relays stay first so existing delegates (and their sockets) are preserved.
  // The bootstrap indexers stay connected too: they hold kind 0 for far more
  // authors than a personal inbox relay, and the backfill subscriptions are
  // sent to them (see isBackfillRelay).
  function updateConnectionUrls() {
    var out = root.relays.slice()
    for (var i = 0; i < root.writeRelays.length; i++) {
      if (out.indexOf(root.writeRelays[i]) === -1) out.push(root.writeRelays[i])
    }
    var boot = Nostr.bootstrapRelays()
    for (var b = 0; b < boot.length; b++) {
      if (out.indexOf(boot[b]) === -1) out.push(boot[b])
    }
    root.allRelays = out
  }

  function isReadRelay(url) {
    return root.relays.indexOf(url) !== -1
  }

  function isWriteRelay(url) {
    return root.writeRelays.indexOf(url) !== -1
  }

  // ---------- Sockets ----------

  function registerSocket(relay) {
    if (root.sockets.indexOf(relay) === -1) root.sockets.push(relay)
    root.socketCount = root.sockets.length
    subscribeTo(relay)
  }

  function unregisterSocket(relay) {
    var i = root.sockets.indexOf(relay)
    if (i !== -1) {
      root.sockets.splice(i, 1)
      root.socketCount = root.sockets.length
    }
  }

  // Profile and parent-event backfill is not role-scoped: bootstrap
  // indexers (nos.lol, purplepag.es, damus) hold kind 0 for far more
  // authors than a personal inbox relay does, so the side fetches go to
  // read relays plus the bootstrap set. The feed and the mute list keep
  // their read/write roles.
  function isBackfillRelay(url) {
    return root.relays.indexOf(url) !== -1 ||
      Nostr.bootstrapRelays().indexOf(url) !== -1
  }

  function broadcastBackfill(msg) {
    var json = JSON.stringify(msg)
    for (var i = 0; i < root.sockets.length; i++) {
      if (!root.isBackfillRelay(root.sockets[i].url)) continue
      root.sockets[i].sendRaw(json)
    }
  }

  // One outbox REQ per relay, counted so the resolve window can close as
  // soon as every relay we asked has answered.
  function askForRelayList(relay) {
    root.pendingOutbox++
    relay.sendRaw(JSON.stringify(["REQ", root.subOutbox, { kinds: [10002], authors: [root.pubkey], limit: 1 }]))
  }

  function subscribeTo(relay) {
    if (root.pubkey === "") return
    if (root.resolving) {
      root.askForRelayList(relay)
      return
    }
    // Background relay-list refresh: outbox lookup on bootstrap relays
    // while the normal subscriptions stay live everywhere else.
    if (root.refreshingRelays && Nostr.bootstrapRelays().indexOf(relay.url) !== -1) {
      root.askForRelayList(relay)
    }
    if (root.relays.indexOf(relay.url) !== -1) {
      relay.sendRaw(JSON.stringify(["REQ", root.subFeed, feedFilter()]))
    }
    if (root.isBackfillRelay(relay.url)) {
      relay.sendRaw(JSON.stringify(["REQ", root.subProfiles, profilesFilter()]))
      relay.sendRaw(JSON.stringify(["REQ", root.subEvents, eventsFilter()]))
    }
    // A relay can be both read and write; the mute list lives on the
    // write side.
    if (root.writeRelays.indexOf(relay.url) !== -1) {
      relay.sendRaw(JSON.stringify(["REQ", root.subMutes, mutesFilter()]))
    }
  }

  function feedKinds() {
    var k = []
    if (root.typeEnabled("reply") || root.typeEnabled("mention")) {
      k.push(1)
      k.push(1111)   // NIP-22 comments
    }
    if (root.typeEnabled("repost")) k.push(6)
    if (root.typeEnabled("reaction")) k.push(7)
    if (root.typeEnabled("zap")) k.push(9735)
    // An empty kinds array would mean "everything" in NIP-01.
    return k.length > 0 ? k : [99999]
  }

  function feedFilter() {
    return {
      kinds: feedKinds(),
      "#p": [root.pubkey],
      limit: 30,
      until: Nostr.nowSec()
    }
  }

  function profilesFilter() {
    return { kinds: [0], authors: Object.keys(root.wantedAuthors) }
  }

  // Own NIP-51 mute list; refreshed on every (re)subscribe.
  function mutesFilter() {
    return { kinds: [10000], authors: [root.pubkey], limit: 1 }
  }

  // Rebuild the mute set as the union of every relay's list, then drop any
  // visible rows from muted authors. Dropped ids are un-forgotten so
  // unmuting can re-pull them.
  function applyMuteList(list, relayUrl) {
    var byRelay = ({})
    for (var k in root.mutedByRelay) byRelay[k] = root.mutedByRelay[k]
    byRelay[String(relayUrl || "unknown")] = list
    root.mutedByRelay = byRelay

    var muted = ({})
    for (var r in byRelay) {
      var entries = byRelay[r]
      for (var i = 0; i < entries.length; i++) muted[entries[i]] = true
    }
    root.mutedAuthors = muted
    root.pruneBlocked()
  }

  function isBlocked(hex) {
    var h = String(hex || "").toLowerCase()
    if (root.mutedAuthors[h]) return true
    return root.blockedAuthors.indexOf(h) !== -1
  }

  // Drop visible rows from blocked/muted authors; un-forget their ids so
  // unblocking re-pulls them on the next resubscribe.
  function pruneBlocked() {
    var kept = []
    var dropped = false
    for (var j = 0; j < root.notifications.length; j++) {
      var n = root.notifications[j]
      if (root.isBlocked(n.author)) {
        root.seen[n.id] = false
        dropped = true
      } else {
        kept.push(n)
      }
    }
    if (dropped) {
      root.notifications = kept
      updateUnread()
    }
  }

  function addBlocked(input) {
    var raw = String(input || "").trim()
    var hex = Nostr.npubToHex(raw)
    if (hex === "") {
      var t = raw.toLowerCase()
      if (/^[0-9a-f]{64}$/.test(t)) hex = t
    }
    if (hex === "" || root.isBlocked(hex)) return false
    var list = root.blockedAuthors.slice()
    list.push(hex)
    root.blockedAuthors = list
    root.saveState()
    root.pruneBlocked()
    return true
  }

  function removeBlocked(hex) {
    var h = String(hex || "").toLowerCase()
    var list = root.blockedAuthors.filter(function (x) { return x !== h })
    if (list.length === root.blockedAuthors.length) return
    root.blockedAuthors = list
    root.saveState()
    if (!root.resolving) root.resubscribe()
  }

  function eventsFilter() {
    var ids = Object.keys(root.wantedEvents)
    if (ids.length > 120) ids = ids.slice(ids.length - 120)
    return { ids: ids }
  }

  // Re-sends the active subscriptions everywhere; also used as a keep-alive.
  function resubscribe() {
    for (var i = 0; i < root.sockets.length; i++) subscribeTo(root.sockets[i])
  }

  Timer {
    interval: 120000
    repeat: true
    running: root.pubkey !== ""
    onTriggered: root.resubscribe()
  }

  // Authors/parent ids accumulate; one debounced REQ per subscription (same
  // id, so it replaces the prior subscription) carries the whole list.
  function wantProfile(hex) {
    if (root.wantedAuthors[hex]) return
    root.wantedAuthors[hex] = true
    profilesTimer.restart()
  }

  function wantEvent(id) {
    if (!id || root.wantedEvents[id]) return
    root.wantedEvents[id] = true
    eventsTimer.restart()
  }

  Timer {
    id: profilesTimer
    interval: 400
    onTriggered: root.broadcastBackfill(["REQ", root.subProfiles, root.profilesFilter()])
  }

  Timer {
    id: eventsTimer
    interval: 400
    onTriggered: root.broadcastBackfill(["REQ", root.subEvents, root.eventsFilter()])
  }

  // ---------- Message handling ----------

  // relayUrl tags which connection an event arrived on, so nevent hints can
  // name a relay that actually has it.
  function handleMessage(text, relayUrl) {
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "") continue
      var msg = null
      try { msg = JSON.parse(line) } catch (e) { continue }
      if (!Array.isArray(msg)) continue
      // Relay frames carry no url: ["EVENT", subId, ev] / ["EOSE", subId].
      if (msg[0] === "EVENT") handleEvent(msg[2], msg[1], String(relayUrl || ""))
      else if (msg[0] === "EOSE") handleEose(msg[1])
      else if (msg[0] === "NOTICE") root.error = String(msg[1] || "")
    }
  }

  function handleEose(subId) {
    if (subId === root.subOutbox) {
      if (root.pendingOutbox > 0) root.pendingOutbox--
      // Every relay we asked has answered: no newer list can arrive on this
      // window, so stop waiting for the deadline.
      if (root.pendingOutbox === 0) root.finishRelayLookup()
      return
    }
    if (subId === root.subFeed && !root.synced) {
      root.synced = true
      updateUnread()
    }
  }

  function handleEvent(ev, subId, relayUrl) {
    if (!ev || typeof ev.pubkey !== "string") return

    if (Nostr.isMyRelayList(ev, root.pubkey)) {
      root.collectRelayList(ev)
      return
    }

    if (typeof ev.id !== "string" || root.seen[ev.id]) return

    if (subId === root.subProfiles && ev.kind === 0) {
      root.seen[ev.id] = true
      var next = ({})
      for (var k in root.profiles) next[k] = root.profiles[k]
      next[ev.pubkey.toLowerCase()] = Nostr.parseProfile(ev.content)
      root.profiles = next
      notifyTimer.restart()   // richer desktop ping as soon as names land
      return
    }

    if (subId === root.subEvents) {
      root.seen[ev.id] = true
      var fe = ({})
      for (var f in root.fetchedEvents) fe[f] = root.fetchedEvents[f]
      fe[ev.id.toLowerCase()] = {
        author: ev.pubkey.toLowerCase(),
        kind: Number(ev.kind) || 0,
        content: String(ev.content || "")
      }
      root.fetchedEvents = fe
      return
    }

    if (subId === root.subMutes) {
      if (ev.kind !== 10000 || ev.pubkey.toLowerCase() !== root.pubkey) return
      root.applyMuteList(Nostr.muteListAuthors(ev), relayUrl)
      return
    }

    if (subId !== root.subFeed) return

    var n = Nostr.notificationFromEvent(ev, root.pubkey)
    if (!n) return
    // Blocked/muted authors never surface; don't mark seen so unblocking
    // re-pulls them.
    if (root.isBlocked(n.author)) return
    // Filtered-out type: don't mark seen, so re-enabling can re-pull it.
    if (!root.typeEnabled(n.type)) return
    root.seen[ev.id] = true
    n.relay = relayUrl
    root.wantProfile(n.author)
    root.wantEvent(n.refId)
    if (!root.synced) root.synced = true

    var list = root.notifications.slice()
    var dup = false
    for (var j = 0; j < list.length; j++) if (list[j].id === n.id) { dup = true; break }
    if (dup) return
    list.push(n)
    list.sort(function (a, b) { return b.created - a.created })
    if (list.length > 100) list = list.slice(0, 100)
    root.notifications = list
    updateUnread()

    // Genuinely fresh while we're caught up - queue a desktop ping. Held for
    // the profile timer so the popup can show the real name + avatar.
    if (ev.created_at > Nostr.nowSec() - 60 && n.created > root.lastRead) {
      var queue = root.pendingNotify.slice()
      queue.push(n)
      root.pendingNotify = queue
      notifyTimer.restart()
    }
  }

  Timer {
    id: notifyTimer
    interval: 2500
    onTriggered: root.flushDesktopNotifications()
  }

  function flushDesktopNotifications() {
    var queue = root.pendingNotify
    root.pendingNotify = []
    for (var i = 0; i < queue.length; i++) sendDesktopNotification(queue[i])
  }

  // One bash job per notification: resolve the avatar to a cached local file
  // (the notification daemon only renders local images), then hand
  // headline/description/image/click-action to omarchy-notification-send.
  // The click action deep-links the referenced event in the configured client.
  function sendDesktopNotification(n) {
    if (root.npub === "" || !root.typeEnabled(n.type) || root.isBlocked(n.author)) return
    var who = Nostr.profileLabel(root.profiles[n.author], n.author)
    var pic = root.profiles[n.author] ? root.profiles[n.author].picture : ""
    var url = root.notificationUrl(n)
    // Positions: $1 avatar dir, $2 avatar file, $3 click url, $4 picture url,
    // $5 headline, $6 description.
    var cmd = "mkdir -p \"$1\" && img=\"\"\n" +
      "if [[ -n \"$4\" ]]; then\n" +
      "  if [[ -s \"$2\" ]] || curl -fsL --max-time 6 -o \"$2\" \"$4\" 2>/dev/null; then img=\"$2\"; fi\n" +
      "fi\n" +
      "if [[ -n $img ]]; then\n" +
      "  exec omarchy-notification-send \"$5\" \"$6\" --app-name Nostr --image \"$img\" --exec xdg-open \"$3\"\n" +
      "else\n" +
      "  exec omarchy-notification-send \"$5\" \"$6\" --app-name Nostr --exec xdg-open \"$3\"\n" +
      "fi\n"
    Quickshell.execDetached(["bash", "-c", cmd, "nostr-notify",
      root.avatarDir, root.avatarDir + "/" + n.author + ".img", url, pic,
      typeHeadline(n.type) + " from " + who,
      n.detail === "" ? "Open to see" : n.detail])
  }

  function typeHeadline(type) {
    if (type === "zap") return "Zap"
    if (type === "repost") return "Repost"
    if (type === "reaction") return "Reaction"
    if (type === "reply") return "Reply"
    if (type === "mention") return "Mention"
    return "Notification"
  }

  // ---------- Client deep links ----------

  // Reactions/reposts/zaps point the browser at the note they target (the e
  // tag); replies/mentions point at the notification event itself.
  function notificationUrl(n) {
    var target = n.refId !== "" ? n.refId : n.id
    var ref = root.fetchedEvents[target]
    var opts = { relays: n.relay ? [n.relay] : [] }
    if (ref) {
      opts.authorHex = ref.author
      opts.kind = ref.kind
    } else if (n.refId === "") {
      opts.authorHex = n.author
      opts.kind = Number(n.kind) || 1
    }
    return Nostr.eventUrl(root.clientName, target, opts)
  }

  function openNotification(n) {
    var url = root.notificationUrl(n)
    if (url !== "") Quickshell.execDetached(["xdg-open", url])
  }

  // ---------- Feed state ----------

  function markRead() {
    root.lastRead = Nostr.nowSec()
    updateUnread()
    root.saveState()
  }

  function clear() {
    root.notifications = []
    root.seen = ({})
  }

  function updateUnread() {
    var n = 0
    for (var i = 0; i < root.notifications.length; i++) {
      if (root.notifications[i].created > root.lastRead) n++
    }
    root.unreadCount = n
  }
}
