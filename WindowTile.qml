import QtQuick
import QtQuick.Effects
import Quickshell.Wayland
import qs.Commons

// One window: its live picture, a badge in the corner, and the app and title
// underneath. Where it sits and how big it is belong to the overlay, which
// morphs it between the window's real place on screen and its grid slot;
// `reveal` (0 → 1) brings the overview's own decorations in with it.
Item {
  id: tile

  required property var window
  property var toplevel: null
  property bool capturing: false
  property bool live: false
  property bool selected: false
  property real reveal: 1
  property string badge: ""
  property string appName: ""
  property string icon: ""
  property real captionHeight: Style.space(22)
  // Hyprland's own look for this window, so at progress 0 the tile is
  // indistinguishable from it: rounded corners and the border drawn outside.
  property real cornerRadius: 0
  property color hyprBorder: "transparent"
  property int hyprBorderWidth: 0

  readonly property color line: Util.alpha(Color.foreground, 0.18)
  readonly property color muted: Util.alpha(Color.foreground, 0.55)
  readonly property bool captured: shot.hasContent
  // Decorations trail the morph so they don't clutter it.
  readonly property real chrome: Math.max(0, Math.min(1, (reveal - 0.55) / 0.45))

  // Dragged by the pointer: the overlay adds dragOffset to where it draws
  // the tile, and asks where it was let go (in the tile's parent).
  property bool draggable: true
  property bool dragging: false
  property point dragOffset: Qt.point(0, 0)

  signal activated()
  signal closeRequested()
  signal pointed()
  signal dragMoved(point at)
  signal dropped(point at)

  // Lifted while dragged.
  scale: dragging ? 0.7 : 1
  rotation: dragging ? -2 : 0
  Behavior on scale { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
  Behavior on rotation { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }

  // Hyprland's border, outside the window like the real one; it hands over to
  // the overview's border as the desktop zooms out.
  Rectangle {
    anchors.fill: parent
    anchors.margins: -tile.hyprBorderWidth
    visible: tile.hyprBorderWidth > 0 && opacity > 0
    opacity: 1 - tile.reveal
    radius: tile.cornerRadius > 0 ? tile.cornerRadius + tile.hyprBorderWidth : 0
    color: "transparent"
    border.width: tile.hyprBorderWidth
    border.color: tile.hyprBorder
    antialiasing: true
  }

  // Shape the picture is clipped to.
  Item {
    id: cornerMask
    anchors.fill: parent
    visible: false
    layer.enabled: tile.cornerRadius > 0
    Rectangle {
      anchors.fill: parent
      radius: tile.cornerRadius
      color: "black"
      antialiasing: true
    }
  }

  Rectangle {
    id: frame
    anchors.fill: parent
    radius: tile.cornerRadius
    color: Util.alpha(Color.foreground, 0.05 * tile.reveal)

    Item {
      id: content
      anchors.fill: parent
      layer.enabled: tile.cornerRadius > 0
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: cornerMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }

      ScreencopyView {
        id: shot
        anchors.fill: parent
        captureSource: tile.capturing && tile.toplevel ? tile.toplevel : null
        live: tile.live
        constraintSize: Qt.size(Math.max(1, width), Math.max(1, height))
      }
    }

    // No frame from the compositor yet: the app's icon and title.
    Column {
      anchors.centerIn: parent
      visible: !shot.hasContent
      spacing: Style.space(10)
      width: parent.width - 2 * Style.space(16)

      Image {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: tile.icon !== ""
        width: Math.min(Style.space(64), tile.height * 0.4)
        height: width
        sourceSize.width: 128
        sourceSize.height: 128
        source: tile.icon
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: tile.window.title || tile.appName
        color: tile.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    // Border on top of the picture, so it never shifts the content.
    Rectangle {
      anchors.fill: parent
      radius: tile.cornerRadius
      antialiasing: true
      color: "transparent"
      opacity: tile.chrome
      border.width: tile.selected ? 2 : 1
      border.color: tile.selected ? Color.accent : tile.line
    }

    Rectangle {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(8)
      visible: tile.badge !== "" && opacity > 0
      opacity: tile.chrome
      height: Style.space(22)
      width: Math.max(height, badgeText.implicitWidth + 2 * Style.space(7))
      color: tile.selected ? Color.accent : Util.alpha(Color.background, 0.85)
      border.width: tile.selected ? 0 : 1
      border.color: tile.line

      Text {
        id: badgeText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: tile.badge
        color: tile.selected ? Color.background : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.weight: Font.Bold
      }
    }
  }

  // Caption, hanging in the gap below the picture.
  Item {
    anchors.top: frame.bottom
    anchors.topMargin: Style.space(8)
    width: parent.width
    height: tile.captionHeight - Style.space(8)
    opacity: tile.chrome
    visible: opacity > 0

    Text {
      id: appLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, parent.width * 0.4)
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: tile.appName
      color: tile.selected ? Color.accent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.weight: tile.selected ? Font.Bold : Font.Normal
    }

    Text {
      anchors.right: parent.right
      anchors.left: appLabel.right
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      elide: Text.ElideRight
      // Nothing to add when the title is just the app's name.
      visible: tile.window.title.toLowerCase() !== tile.appName.toLowerCase()
      text: tile.window.title
      color: tile.selected ? Color.foreground : tile.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: frame
    enabled: tile.reveal > 0.99
    hoverEnabled: true
    preventStealing: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: tile.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

    // Measured in the parent's coordinates: the tile itself moves with the
    // pointer, so its own coordinates would chase themselves.
    property point pressAt: Qt.point(0, 0)
    property bool moved: false

    onEntered: tile.pointed()
    onPressed: (mouse) => {
      pressAt = mapToItem(tile.parent, mouse.x, mouse.y)
      moved = false
    }
    onPositionChanged: (mouse) => {
      if (!pressed || !tile.draggable || !(pressedButtons & Qt.LeftButton)) return
      var at = mapToItem(tile.parent, mouse.x, mouse.y)
      var dx = at.x - pressAt.x
      var dy = at.y - pressAt.y
      if (!moved && Math.hypot(dx, dy) < Style.space(8)) return
      moved = true
      tile.dragging = true
      tile.dragOffset = Qt.point(dx, dy)
      tile.dragMoved(at)
    }
    onReleased: (mouse) => {
      if (!tile.dragging) return
      var at = mapToItem(tile.parent, mouse.x, mouse.y)
      tile.dragging = false
      tile.dragOffset = Qt.point(0, 0)
      tile.dropped(at)
    }
    onCanceled: {
      tile.dragging = false
      tile.dragOffset = Qt.point(0, 0)
    }
    onClicked: (mouse) => {
      if (moved) return
      if (mouse.button === Qt.MiddleButton) tile.closeRequested()
      else tile.activated()
    }
  }
}
