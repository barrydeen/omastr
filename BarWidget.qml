import QtQuick
import Qt5Compat.GraphicalEffects
import qs.Commons
import qs.Ui

// Bar slot for the Nostr plugin: bell icon, unread badge, and the host for
// the feed popup (Panel.qml, kept loaded so the relay sockets stay up).
BarWidget {
  id: root
  moduleName: "io.github.barrydeen.omastr"

  readonly property int unread: panelLoader.item ? panelLoader.item.unreadCount : 0

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.iconSlot
    tooltipText: root.unread > 0
      ? "Nostr - " + root.unread + " unread"
      : "Nostr"

    // 8-bit nostr mark (erikhodl/nostr-8bit-icons), tinted to the bar's
    // foreground so it tracks the active theme.
    iconComponent: Component {
      Image {
        anchors.fill: parent
        source: "icons/nostr_basic.png"
        fillMode: Image.PreserveAspectFit
        layer.enabled: true
        layer.smooth: true
        layer.effect: ColorOverlay {
          color: button.foreground
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton && panelLoader.item) panelLoader.item.clientRefresh()
      else root.togglePanel()
    }

    Rectangle {
      visible: root.unread > 0
      width: Math.max(badgeLabel.implicitWidth + Style.space(4), height)
      height: badgeLabel.implicitHeight + Style.space(2)
      radius: height / 2
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: -Style.space(2)
      anchors.topMargin: -Style.space(1)
      color: Color.urgent

      Text {
        id: badgeLabel
        anchors.centerIn: parent
        text: root.unread > 99 ? "99+" : root.unread
        color: "white"
        font.family: button.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }
  }
}
