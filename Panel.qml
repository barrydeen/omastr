import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Nostr.js" as Nostr

// Popup content for the Nostr bar widget: npub setup on first run, then the
// live notifications feed. The relay Repeater and NostrClient live here, not
// in the popup window, so the feed keeps receiving while the popup is closed
// (this item is always loaded by the bar widget's Loader).
Panel {
  id: root
  moduleName: "io.github.barrydeen.omastr"
  ipcTarget: "io.github.barrydeen.omastr"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property int unreadCount: client.unreadCount

  function open() {
    root.controller.show()
    client.markRead()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function clientRefresh() {
    client.resubscribe()
  }

  // Two-step disconnect: the button arms itself, asks for a second click,
  // and disarms after a few seconds so a stray "settings-looking" click never
  // wipes the identity on its own.
  property bool confirmDisconnect: false
  property bool showSettings: false
  Timer {
    id: disconnectResetTimer
    interval: 3000
    onTriggered: root.confirmDisconnect = false
  }

  function debugStatus() {
    console.log("nostr-debug:", JSON.stringify({
      npub: client.npub.substring(0, 12),
      pubkeySet: client.pubkey.length > 0,
      resolving: client.resolving,
      synced: client.synced,
      sockets: client.socketCount,
      relays: client.relays.length,
      notifs: client.notifications.length,
      muted: Object.keys(client.mutedAuthors).length,
      error: client.error,
      settingsMode: root.showSettings,
      gearW: navButton.width
    }))
  }

  IpcHandler {
    target: "io.github.barrydeen.omastr.debug"

    function status(): void { root.debugStatus() }
    function settings(): void { root.showSettings = !root.showSettings }
    function toggle(group: string): void {
      client.setGroupEnabled(group, !client.isGroupEnabled(group))
    }
    function firstUrl(): void {
      if (client.notifications.length > 0)
        console.log("nostr-debug: url", client.notificationUrl(client.notifications[0]))
    }
    function notifyTest(): void {
      if (client.notifications.length > 0)
        client.sendDesktopNotification(client.notifications[0])
    }
  }

  // Relative timestamps age in place while the popup is open.
  property date clockNow: clock.date
  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.clockNow = date
  }

  NostrClient {
    id: client
  }

  // One Relay delegate per url; recreates whenever the relay list changes
  // (including the bootstrap -> author-relay-list swap during setup).
  Repeater {
    model: client.pubkey === "" ? [] : client.relays
    Relay {
      required property string modelData
      url: modelData
      engine: client
    }
  }

  function typeColor(type) {
    if (type === "zap") return "#e8a33d"
    if (type === "repost") return "#4aa3df"
    if (type === "reaction") return "#e06c9f"
    if (type === "reply") return "#7fb069"
    return "#9a87cf"
  }

  function typeIcon(type) {
    if (type === "zap") return "⚡"
    if (type === "repost") return "🔁"
    if (type === "reaction") return "❤️"
    if (type === "reply") return "💬"
    return "📣"
  }

  function typeLabel(type) {
    if (type === "zap") return "Zap"
    if (type === "repost") return "Repost"
    if (type === "reaction") return "Reaction"
    if (type === "reply") return "Reply"
    return "Mention"
  }

  function authorName(hex) {
    var p = client.profiles[hex]
    return p ? Nostr.profileLabel(p, hex) : Nostr.shortHex(hex)
  }

  function authorPicture(hex) {
    var p = client.profiles[hex]
    return p ? p.picture : ""
  }

  // The quoted parent note, once it has been fetched, so reactions/reposts/
  // zaps/replies carry their context (rendered in italics below the detail).
  function composeContext(n) {
    if (!n.refId) return ""
    var ref = client.fetchedEvents[n.refId]
    if (!ref) return ""
    return Nostr.contextText(ref, client.pubkey, root.authorName(ref.author))
  }

  function statusLine() {
    if (client.pubkey === "") return "Your nostr notifications"
    if (client.resolving) return "Looking up your relays…"
    var hosts = client.relays.map(function (u) {
      return String(u).replace(/^wss:\/\//, "").split("/")[0]
    })
    var shown = hosts.slice(0, 3).join(" · ")
    if (hosts.length > 3) shown += " +" + (hosts.length - 3)
    if (client.socketCount === 0) return "Connecting to " + shown + "…"
    var line = client.socketCount + "/" + client.relays.length + " relays: " + shown
    line += " · " + client.notifications.length + (client.synced ? "" : "+") + " notification"
    line += client.notifications.length === 1 ? "" : "s"
    return line
  }


  // ---------------- Popup ----------------
  //
  // Fixed-height popup: identity header pinned to the top, only the feed
  // column scrolls.

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: client.pubkey === "" ? setupField : notifScroll
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.cappedContentHeight(client.pubkey === "" ? Style.space(220) : Style.space(560))

    // ---------- Header ----------
    Item {
      id: header
      width: parent.width
      anchors.top: parent.top
      implicitHeight: Math.max(ownAvatarBg.height, headerLabels.height, navButton.implicitHeight, backButton.implicitHeight)

      Button {
        id: backButton
        visible: root.showSettings
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "←"
        tooltipText: "Back"
        foreground: root.bar ? root.bar.foreground : Color.popups.text
        onClicked: root.showSettings = false
      }

      // Our own avatar, the same circular treatment as the feed rows.
      Rectangle {
        id: ownAvatarBg
        visible: !root.showSettings && client.pubkey !== ""
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        height: width
        radius: width / 2
        color: Qt.hsla((parseInt(client.pubkey.substring(0, 2), 16) % 360) / 360, 0.35, 0.32, 1.0)

        readonly property var profile: client.profiles[client.pubkey]

        Text {
          anchors.centerIn: parent
          visible: !ownAvatarImage.visible
          text: root.authorName(client.pubkey).charAt(0).toUpperCase()
          color: "white"
          opacity: 0.85
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Image {
          id: ownAvatarImage
          anchors.fill: parent
          visible: status === Image.Ready
          source: ownAvatarBg.profile ? ownAvatarBg.profile.picture : ""
          sourceSize.width: Style.space(56)
          sourceSize.height: Style.space(56)
          fillMode: Image.PreserveAspectCrop
          layer.enabled: true
          layer.smooth: true
          layer.effect: OpacityMask {
            maskSource: ownAvatarMask
          }
        }

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: "transparent"
          border.width: 1
          border.color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.2)
        }

        Rectangle {
          id: ownAvatarMask
          width: ownAvatarBg.width
          height: ownAvatarBg.height
          radius: width / 2
          visible: false
        }
      }

      Column {
        id: headerLabels
        anchors.left: root.showSettings ? backButton.right : (client.pubkey !== "" ? ownAvatarBg.right : parent.left)
        anchors.leftMargin: Style.space(10)
        anchors.right: navButton.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          text: root.showSettings ? "Settings" : (client.pubkey !== "" ? root.authorName(client.pubkey) : "Nostr")
          width: parent.width
          elide: Text.ElideRight
          color: root.bar ? root.bar.foreground : Color.popups.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          text: client.error !== ""
                  ? client.error
                  : (root.showSettings ? statusLine() : client.npub)
          width: parent.width
          elide: client.error === "" && !root.showSettings ? Text.ElideMiddle : Text.ElideRight
          color: client.error !== "" ? Color.urgent : Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.6)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      Button {
        id: navButton
        visible: !root.showSettings && client.pubkey !== ""
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "⚙"
        tooltipText: "Settings"
        foreground: root.bar ? root.bar.foreground : Color.popups.text
        onClicked: root.showSettings = true
      }
    }

    PanelSeparator {
      id: headerSep
      visible: client.pubkey !== ""
      width: parent.width
      anchors.top: header.bottom
      anchors.topMargin: Style.space(10)
    }

    // ---------- Scrolling body: setup or feed ----------
    Flickable {
      id: notifScroll
      width: parent.width
      anchors.top: headerSep.visible ? headerSep.bottom : header.bottom
      anchors.topMargin: Style.space(10)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(8)
      contentWidth: width
      contentHeight: bodyCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      focus: true
      interactive: contentHeight > height

      Column {
        id: bodyCol
        width: notifScroll.width
        spacing: Style.space(10)

        // Setup
        Column {
          visible: client.pubkey === ""
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Enter your npub to follow your notifications. It's your public, read-only key — nothing here can sign or send on your behalf."
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.75)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          TextField {
            id: setupField
            width: parent.width
            placeholderText: "npub1…"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onAccepted: client.configure(text)
          }

          Button {
            text: "Connect"
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onClicked: client.configure(setupField.text)
          }
        }

        Text {
          visible: client.pubkey !== "" && !root.showSettings && client.notifications.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          text: client.synced
            ? "No notifications yet. Zaps, replies, reposts and reactions will appear here as they arrive."
            : "Loading your notifications…"
          color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.6)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: (client.pubkey === "" || root.showSettings) ? [] : client.notifications

          Item {
            id: row
            required property var modelData
            required property int index

            readonly property var profile: client.profiles[modelData.author]
            readonly property bool unread: modelData.created > client.lastRead
            readonly property string contextNote: root.composeContext(modelData)

            width: parent.width
            implicitHeight: rowContent.implicitHeight + Style.space(6)

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: client.openNotification(row.modelData)
            }

            Rectangle {
              visible: row.unread
              width: Style.space(5)
              height: width
              radius: width / 2
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.topMargin: Style.space(12)
              color: Color.accent
            }

            Item {
              id: rowContent
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.top: parent.top
              implicitHeight: Math.max(rowAvatar.height,
                rowMedia.visible ? rowMedia.y + rowMedia.height
                  : (rowContext.visible ? rowContext.y + rowContext.implicitHeight
                    : (rowDetail.visible ? rowDetail.y + rowDetail.implicitHeight
                                         : rowNameRow.y + rowNameRow.implicitHeight)))

              // Circular avatar, falling back to a colored initial. The
              // picture is round-masked via OpacityMask because Item clip
              // is rectangular.
              Item {
                id: rowAvatar
                width: Style.space(36)
                height: Style.space(36)

                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: Qt.hsla((parseInt(modelData.author.substring(0, 2), 16) % 360) / 360, 0.35, 0.32, 1.0)
                }

                Text {
                  anchors.centerIn: parent
                  visible: rowImage.status !== Image.Ready
                  text: root.authorName(modelData.author).charAt(0).toUpperCase()
                  color: "white"
                  opacity: 0.85
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Image {
                  id: rowImage
                  anchors.fill: parent
                  visible: status === Image.Ready
                  source: row.profile ? row.profile.picture : ""
                  sourceSize.width: Style.space(72)
                  sourceSize.height: Style.space(72)
                  fillMode: Image.PreserveAspectCrop
                  layer.enabled: true
                  layer.smooth: true
                  layer.effect: OpacityMask {
                    maskSource: avatarMask
                  }
                }

                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: "transparent"
                  border.width: 1
                  border.color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.2)
                }

                Rectangle {
                  id: avatarMask
                  width: rowAvatar.width
                  height: rowAvatar.height
                  radius: width / 2
                  visible: false
                }
              }

              Text {
                id: rowTime
                anchors.right: parent.right
                anchors.top: parent.top
                text: Nostr.timeAgo(modelData.created, root.clockNow.getTime() / 1000)
                color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.55)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
              }

              Item {
                id: rowNameRow
                anchors.left: rowAvatar.right
                anchors.leftMargin: Style.space(10)
                anchors.right: rowTime.left
                anchors.rightMargin: Style.space(8)
                anchors.top: parent.top
                height: rowName.implicitHeight

                Row {
                  spacing: Style.space(6)

                  Text {
                    id: rowName
                    text: root.authorName(modelData.author)
                    color: root.bar ? root.bar.foreground : Color.popups.text
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, rowNameRow.width - rowChip.width - Style.space(6))
                  }

                  Rectangle {
                    id: rowChip
                    height: rowChipLabel.implicitHeight + Style.space(4)
                    radius: height / 2
                    color: Util.alpha(root.typeColor(modelData.type), 0.16)
                    border.width: 1
                    border.color: Util.alpha(root.typeColor(modelData.type), 0.45)

                    Text {
                      id: rowChipLabel
                      anchors.centerIn: parent
                      leftPadding: Style.space(7)
                      rightPadding: Style.space(7)
                      text: root.typeIcon(modelData.type) + " " + root.typeLabel(modelData.type)
                      color: root.typeColor(modelData.type)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: Object.keys(client.mutedAuthors).length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: Object.keys(client.mutedAuthors).length + " muted accounts hidden from notifications."
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
                  }
                }
              }

              Text {
                id: rowDetail
                anchors.left: rowNameRow.left
                anchors.right: parent.right
                anchors.top: rowNameRow.bottom
                anchors.topMargin: Style.space(2)
                visible: modelData.detail !== ""
                text: modelData.detail
                color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.7)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 3
                elide: Text.ElideRight
              }

              // Quoted parent note, in italics instead of an arrow prefix.
              Text {
                id: rowContext
                anchors.left: rowNameRow.left
                anchors.right: parent.right
                anchors.top: rowDetail.visible ? rowDetail.bottom : rowNameRow.bottom
                anchors.topMargin: Style.space(2)
                visible: row.contextNote !== ""
                text: row.contextNote
                color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.5)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.italic: true
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              // Inline media: images render directly; videos load paused
              // with a play overlay (muted until played).
              Rectangle {
                id: rowMedia
                readonly property bool isImage: modelData.media && modelData.media.type === "image"
                readonly property bool isVideo: modelData.media && modelData.media.type === "video"
                visible: isImage || isVideo
                anchors.left: rowNameRow.left
                anchors.top: rowContext.visible ? rowContext.bottom
                                                : (rowDetail.visible ? rowDetail.bottom : rowNameRow.bottom)
                anchors.topMargin: Style.space(4)
                width: Style.space(240)
                height: visible ? Style.space(150) : 0
                radius: Style.space(8)
                clip: true
                border.width: 1
                border.color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.15)
                color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.06)

                Image {
                  anchors.fill: parent
                  visible: rowMedia.isImage
                  source: rowMedia.isImage ? modelData.media.url : ""
                  sourceSize.width: Style.space(480)
                  sourceSize.height: Style.space(300)
                  fillMode: Image.PreserveAspectCrop
                }

                Video {
                  id: rowVideo
                  anchors.fill: parent
                  visible: rowMedia.isVideo
                  source: rowMedia.isVideo ? modelData.media.url : ""
                  muted: true
                  Component.onCompleted: pause()
                }

                Rectangle {
                  anchors.centerIn: parent
                  visible: rowMedia.isVideo
                  opacity: rowVideo.playbackState === Video.PlayingState ? 0.0 : 1.0
                  Behavior on opacity { NumberAnimation { duration: 120 } }
                  width: Style.space(36)
                  height: width
                  radius: width / 2
                  color: Util.alpha("#000000", 0.55)

                  Text {
                    anchors.centerIn: parent
                    text: "▶"
                    color: "white"
                    font.pixelSize: Style.font.body
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (rowMedia.isVideo)
                      rowVideo.playbackState === Video.PlayingState ? rowVideo.pause() : rowVideo.play()
                    else
                      client.openNotification(row.modelData)
                  }
                }
              }
            }
          }
        }

        // ---------- Settings view ----------
        Column {
          visible: root.showSettings && client.pubkey !== ""
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: "WEB CLIENT"
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Dropdown {
            width: Style.space(200)
            label: "Open in"
            value: client.clientName
            options: Nostr.clientOptions()
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            onChanged: function(value) { client.setClientName(value) }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Where clicking a notification (or pressing Enter) opens the event."
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { width: parent.width }

          Text {
            text: "NOTIFICATIONS"
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: [
                { group: "replies", label: "Replies & mentions" },
                { group: "reposts", label: "Reposts" },
                { group: "reactions", label: "Reactions" },
                { group: "zaps", label: "Zaps" }
              ]

              Toggle {
                required property var modelData
                width: parent.width
                label: modelData.label
                checked: client.isGroupEnabled(modelData.group)
                foreground: root.bar ? root.bar.foreground : Color.popups.text
                onClicked: client.setGroupEnabled(modelData.group, !checked)
              }
            }
          }

          PanelSeparator { width: parent.width }

          Text {
            text: "ACCOUNT"
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            width: parent.width
            elide: Text.ElideMiddle
            text: client.npub
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.65)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: root.confirmDisconnect ? "Confirm disconnect" : "Disconnect"
            tooltipText: "Forget this npub"
            foreground: root.confirmDisconnect ? Color.urgent : (root.bar ? root.bar.foreground : Color.popups.text)
            onClicked: {
              if (root.confirmDisconnect) {
                root.confirmDisconnect = false
                root.showSettings = false
                client.disconnectIdentity()
              } else {
                root.confirmDisconnect = true
                disconnectResetTimer.restart()
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This plugin is read-only — it never signs or publishes."
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { width: parent.width }

          Text {
            text: "RELAYS (NIP-65)"
            color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Column {
            width: parent.width
            spacing: Style.space(3)

            Repeater {
              model: client.relays

              Text {
                required property var modelData
                width: parent.width
                elide: Text.ElideMiddle
                text: "•  " + modelData.replace("wss://", "").replace("ws://", "")
                color: Util.alpha(root.bar ? root.bar.foreground : Color.popups.text, 0.65)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }
  }
}
