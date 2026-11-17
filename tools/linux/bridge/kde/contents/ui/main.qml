import QtQuick
import org.kde.kwin

Item {
  id: root
  property string last: ""

  function collect() {
    var list = []
    var all = Workspace.windowList()
    for (var i = 0; i < all.length; i++) {
      var w = all[i]
      if (!w.normalWindow) continue
      list.push({
        pid: w.pid,
        class: w.resourceClass.toString(),
        instance: w.resourceName.toString(),
        active: w === Workspace.activeWindow,
        minimized: w.minimized
      })
    }
    return JSON.stringify({windows: list})
  }

  function send(force) {
    var json = collect()
    if (!force && json === last) return
    last = json
    call.arguments = [json]
    call.call()
  }

  DBusCall {
    id: call
    service: "org.wolium.Bridge"
    path: "/org/wolium/Bridge"
    dbusInterface: "org.wolium.Bridge"
    method: "Report"
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: root.send(false)
  }

  Timer {
    interval: 10000
    repeat: true
    running: true
    onTriggered: root.send(true)
  }

  Connections {
    target: Workspace
    function onWindowActivated() { root.send(false) }
    function onWindowAdded() { root.send(false) }
    function onWindowRemoved() { root.send(false) }
  }
}
