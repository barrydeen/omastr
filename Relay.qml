import QtQuick
import QtWebSockets

// One relay connection. Mounted by the Repeater in Panel.qml, one delegate per
// relay url. Owns its WebSocket (with a fixed retry delay on drop) and talks to
// the NostrClient through the `engine` property: register on connect so the
// client can (re)subscribe, unregister on drop so broadcasts skip dead sockets.
Item {
  id: root

  required property string url
  required property var engine

  property bool connected: ws.status === WebSocket.Open

  function sendRaw(json) {
    if (ws.status === WebSocket.Open) ws.sendTextMessage(json)
  }

  WebSocket {
    id: ws
    url: root.url
    active: true

    onTextMessageReceived: function(text) {
      root.engine.handleMessage(text, root.url)
    }

    // A failed handshake also lands in Unconnected, so one transition covers
    // clean drops, down relays, and DNS flakes alike.
    onStatusChanged: {
      if (ws.status === WebSocket.Open) {
        root.engine.registerSocket(root)
      } else if (ws.status === WebSocket.Unconnected) {
        root.engine.unregisterSocket(root)
        retryTimer.restart()
      }
    }

    Component.onDestruction: root.engine.unregisterSocket(root)
  }

  // Force a fresh connection attempt after each drop; a failed attempt
  // re-triggers the Unconnected path, so this doubles as the retry cadence.
  Timer {
    id: retryTimer
    interval: 15000
    onTriggered: {
      ws.active = false
      Qt.callLater(function() { ws.active = true })
    }
  }
}
