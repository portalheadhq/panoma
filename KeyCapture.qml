import QtQuick
import qs.Commons
import "Model.js" as Model

// A settings row for a key: shows the current one and, when clicked, records
// the next key pressed. `mode` "combo" takes a Hyprland combo (needs a
// modifier, like SUPER + E); "key" takes one character for inside the
// overview. Esc cancels. While recording, the overlay inhibits Hyprland's
// own shortcuts (see `capturing`), so pressing a combo that is already bound
// reaches this row instead of running.
Item {
  id: row

  property string label: ""
  property string description: ""
  property string value: ""
  property string mode: "combo"
  // Shown under the row in the accent colour (a conflict, say).
  property string warning: ""
  property string placeholder: "…"
  property string invalidText: ""
  property bool capturing: false

  signal captured(string value)

  property bool rejected: false

  implicitHeight: content.implicitHeight + Style.space(16)

  function start() {
    rejected = false
    capturing = true
    catcher.forceActiveFocus()
  }

  function stop() {
    capturing = false
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)

    Item {
      width: parent.width
      height: Math.max(texts.implicitHeight, button.height)

      Column {
        id: texts
        anchors.left: parent.left
        anchors.right: button.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: row.label
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
        }
        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: row.description
          color: Util.alpha(Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Rectangle {
        id: button
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(30)
        width: Math.max(Style.space(64), keyText.implicitWidth + Style.space(20))
        radius: Style.space(4)
        color: row.capturing ? Util.alpha(Color.accent, 0.18) : Util.alpha(Color.foreground, 0.06)
        border.width: 1
        border.color: row.capturing ? Color.accent : Util.alpha(Color.foreground, 0.2)

        Text {
          id: keyText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: row.capturing ? row.placeholder : (row.value || "—")
          color: row.capturing ? Color.accent : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.weight: Font.DemiBold
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: row.capturing ? row.stop() : row.start()
        }
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: row.rejected ? row.invalidText : row.warning
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // Takes the key presses while recording.
  Item {
    id: catcher
    focus: row.capturing

    Keys.onPressed: (event) => {
      if (!row.capturing) return
      event.accepted = true
      if (event.key === Qt.Key_Escape) { row.stop(); return }
      // A modifier on its own: wait for the key that goes with it.
      if (event.key === Qt.Key_Shift || event.key === Qt.Key_Control || event.key === Qt.Key_Alt
          || event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R
          || event.key === Qt.Key_AltGr) return
      var value = row.mode === "combo" ? Model.comboFromEvent(event.key, event.modifiers) : Model.normalizeKey(event.text)
      if (value === "") {
        row.rejected = true
        return
      }
      row.rejected = false
      row.stop()
      row.captured(value)
    }
  }
}
