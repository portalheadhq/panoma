import QtQuick
import qs.Commons

// The running apps, shown only while Panoma is open. Icons come from the
// installed icon theme; apps with nothing on this workspace sit back a little.
// Clicking one goes to that app; right-clicking shows all of its windows,
// wherever they are.
Rectangle {
  id: dock

  property var apps: []
  property string activeKey: ""
  property var iconFor: function(appId) { return "" }
  property var nameFor: function(appId) { return appId }

  signal picked(var app)
  signal expanded(var app)

  property int iconSize: Style.space(48)
  readonly property int slotWidth: iconSize + Style.space(20)

  implicitWidth: row.implicitWidth + 2 * Style.space(18)
  // Sits on the bottom edge of the screen: rounded on top, square where it
  // meets the edge, a little more room under the labels than above the icons.
  property real cornerRadius: 0

  implicitHeight: row.implicitHeight + Style.space(14) + Style.space(14)
  color: Util.alpha(Color.background, 0.9)
  border.width: 1
  border.color: Util.alpha(Color.foreground, 0.18)
  topLeftRadius: cornerRadius
  topRightRadius: cornerRadius
  bottomLeftRadius: 0
  bottomRightRadius: 0

  Row {
    id: row
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: Style.space(14)
    spacing: Style.space(14)

    Repeater {
      model: dock.apps

      Column {
        id: slot

        required property var modelData
        readonly property bool active: modelData.key === dock.activeKey
        readonly property string icon: dock.iconFor(modelData.appId)

        width: dock.slotWidth
        spacing: Style.space(6)
        opacity: active || modelData.onWorkspace ? 1 : 0.55

        Rectangle {
          id: well
          anchors.horizontalCenter: parent.horizontalCenter
          width: dock.iconSize
          height: width
          color: slot.active ? Util.alpha(Color.accent, 0.18) : "transparent"
          border.width: slot.active ? 2 : 0
          border.color: Color.accent

          Image {
            anchors.centerIn: parent
            visible: slot.icon !== ""
            width: Math.round(dock.iconSize * 0.78)
            height: width
            sourceSize.width: 96
            sourceSize.height: 96
            source: slot.icon
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
          }

          // No icon installed: the app's initial.
          Text {
            anchors.centerIn: parent
            visible: slot.icon === ""
            textFormat: Text.PlainText
            text: String(dock.nameFor(slot.modelData.appId) || "?").charAt(0).toUpperCase()
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.weight: Font.Bold
          }

          // Window count, when there is more than one.
          Rectangle {
            visible: slot.modelData.count > 1
            x: parent.width - width / 2 - Style.space(2)
            y: -height / 2 + Style.space(2)
            height: Style.space(16)
            width: Math.max(height, countText.implicitWidth + Style.space(6))
            color: slot.active ? Color.accent : Color.foreground

            Text {
              id: countText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: String(slot.modelData.count)
              color: Color.background
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.weight: Font.Bold
            }
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => {
              if (mouse.button === Qt.RightButton) dock.expanded(slot.modelData)
              else dock.picked(slot.modelData)
            }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: String(dock.nameFor(slot.modelData.appId) || "").toLowerCase()
          color: slot.active ? Color.accent : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: slot.active ? Font.Bold : Font.Normal
        }
      }
    }
  }
}
