import QtQuick
import qs.Commons
import "Model.js" as Model

// The workspaces along the top of the overview, each a small map of where its
// windows sit, plus "+" for a new one. Click one to go there; drop a window
// on one to send it there. `dropTarget` is the workspace a dragged window is
// over (0 = the new-workspace tile, -1 none).
Item {
  id: strip

  property var workspaces: []
  property var offset: ({ x: 0, y: 0 })
  property real areaWidth: 1
  property real areaHeight: 1
  property int dropTarget: -1
  property int newWorkspaceId: 1
  property var iconFor: function(appId) { return "" }
  property var nameFor: function(appId) { return appId }
  property var geometryFor: function(w) { return w }

  // Ids don't cross files, so the overlay passes its translated label in.
  property string dropLabel: "drop to move"

  signal picked(int workspaceId)

  readonly property int mapHeight: Style.space(72)
  readonly property real mapWidth: Math.round(mapHeight * Math.max(0.5, areaWidth / Math.max(1, areaHeight)))
  readonly property real mapScale: mapWidth / Math.max(1, areaWidth)
  readonly property int labelHeight: Style.space(20)

  implicitWidth: row.implicitWidth
  implicitHeight: mapHeight + Style.space(6) + labelHeight

  // Workspace id under a point in this item's coordinates: 0 for the new
  // workspace tile, -1 for nothing.
  function workspaceAt(x, y) {
    for (var i = 0; i < maps.count; i++) {
      var item = maps.itemAt(i)
      var p = item.mapFromItem(strip, x, y)
      if (p.x >= 0 && p.y >= 0 && p.x <= item.width && p.y <= mapHeight) return item.workspaceId
    }
    var n = newTile.mapFromItem(strip, x, y)
    if (n.x >= 0 && n.y >= 0 && n.x <= newTile.width && n.y <= newTile.height) return 0
    return -1
  }

  Row {
    id: row
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(16)

    Repeater {
      id: maps
      model: strip.workspaces

      Column {
        id: ws

        required property var modelData
        readonly property int workspaceId: modelData.id
        readonly property bool target: strip.dropTarget === modelData.id && !modelData.current

        spacing: Style.space(6)
        width: strip.mapWidth

        Rectangle {
          width: strip.mapWidth
          height: strip.mapHeight
          clip: true
          color: Util.alpha(Color.background, 0.75)
          border.width: ws.modelData.current || ws.target ? 2 : 1
          border.color: ws.modelData.current || ws.target ? Color.accent : Util.alpha(Color.foreground, 0.18)

          Repeater {
            model: ws.modelData.windows

            Rectangle {
              required property var modelData
              readonly property var g: strip.geometryFor(modelData)
              readonly property string icon: strip.iconFor(modelData.appId)

              x: (g.x - strip.offset.x) * strip.mapScale
              y: (g.y - strip.offset.y) * strip.mapScale
              width: Math.max(4, g.width * strip.mapScale)
              height: Math.max(4, g.height * strip.mapScale)
              color: Util.alpha(Color.foreground, 0.1)
              border.width: 1
              border.color: Util.alpha(Color.foreground, 0.28)

              Image {
                anchors.centerIn: parent
                visible: parent.icon !== "" && parent.width > Style.space(18) && parent.height > Style.space(18)
                width: Math.min(Style.space(18), parent.width * 0.6, parent.height * 0.6)
                height: width
                sourceSize.width: 48
                sourceSize.height: 48
                source: parent.icon
                fillMode: Image.PreserveAspectFit
                asynchronous: true
              }
            }
          }

          Rectangle {
            visible: ws.target
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: Style.space(5)
            height: Style.space(18)
            width: dropText.implicitWidth + Style.space(12)
            color: Color.accent

            Text {
              id: dropText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: strip.dropLabel
              color: Color.background
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.weight: Font.Bold
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: strip.picked(ws.workspaceId)
          }
        }

        Item {
          width: parent.width
          height: strip.labelHeight

          Text {
            id: idLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: String(ws.workspaceId)
            color: ws.modelData.current ? Color.accent : Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.weight: ws.modelData.current ? Font.Bold : Font.Normal
          }

          Text {
            anchors.left: idLabel.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: {
              var seen = {}
              var names = []
              for (var i = 0; i < ws.modelData.windows.length; i++) {
                var n = String(strip.nameFor(ws.modelData.windows[i].appId)).toLowerCase()
                if (!seen[n]) { seen[n] = true; names.push(n) }
              }
              return names.join(", ")
            }
            color: Util.alpha(Color.foreground, 0.55)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // New workspace: click to go to an empty one, drop to send a window there.
    Rectangle {
      id: newTile
      width: Style.space(48)
      height: strip.mapHeight
      color: strip.dropTarget === 0 ? Util.alpha(Color.accent, 0.18) : Util.alpha(Color.background, 0.5)
      border.width: strip.dropTarget === 0 ? 2 : 1
      border.color: strip.dropTarget === 0 ? Color.accent : Util.alpha(Color.foreground, 0.28)

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "+"
        color: strip.dropTarget === 0 ? Color.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.display
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: strip.picked(strip.newWorkspaceId)
      }
    }
  }
}
