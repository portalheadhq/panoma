import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Panoma's settings, as a sheet over the overview: four groups behind a
// segmented control, every change applied live (the overview behind it shows
// the result) and saved by the overlay. This item only asks for changes
// (`setValue`); it never writes anything itself.
Rectangle {
  id: sheet

  property var cfg: ({})
  property real cornerRadius: 0
  // Hyprland side of the Atajos group, filled in by the overlay.
  property bool hyprIntegrated: true
  property string hyprError: ""
  // A combo waiting for "use it anyway", and what already uses it.
  property string pendingBind: ""
  property string pendingConflict: ""

  property string tab: "gestures"

  readonly property bool capturing: openRow.capturing || filterRow.capturing || closeRow.capturing || settingsRow.capturing

  signal setValue(string path, var value)
  signal requestBind(string combo)
  signal confirmBind()
  signal cancelBind()
  signal closeRequested()

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  color: Util.alpha(Color.background, 0.97)
  border.width: 1
  border.color: Util.alpha(Color.foreground, 0.18)
  radius: cornerRadius

  // Clicks inside the sheet stay inside it.
  MouseArea { anchors.fill: parent }

  Keys.onPressed: (event) => {
    if (event.key === Qt.Key_Escape && !sheet.capturing) {
      event.accepted = true
      sheet.closeRequested()
    }
  }

  readonly property int pad: Style.space(20)

  // ---- Title + tabs ----

  Item {
    id: top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: sheet.pad
    height: titleRow.height + Style.space(14) + tabs.implicitHeight

    Item {
      id: titleRow
      width: parent.width
      height: Style.space(28)

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: strings.t("settings.title")
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.weight: Font.Bold
      }

      Rectangle {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        height: width
        radius: Style.space(4)
        color: closeArea.containsMouse ? Util.alpha(Color.foreground, 0.1) : "transparent"

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "×"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
        }

        MouseArea {
          id: closeArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: sheet.closeRequested()
        }
      }
    }

    ButtonGroup {
      id: tabs
      anchors.top: titleRow.bottom
      anchors.topMargin: Style.space(14)
      options: [
        { value: "gestures", label: strings.t("tab.gestures") },
        { value: "look", label: strings.t("tab.look") },
        { value: "show", label: strings.t("tab.show") },
        { value: "keys", label: strings.t("tab.keys") }
      ]
      value: sheet.tab
      onChanged: (value) => { sheet.tab = value; scroller.contentY = 0 }
    }
  }

  // ---- Rows ----

  component SliderRow: Column {
    id: sr
    property string label: ""
    property string description: ""
    property string valueText: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 1
    property real step: 0.05
    property bool integer: false
    signal moved(real value)

    width: parent ? parent.width : 0
    spacing: Style.space(6)
    topPadding: Style.space(8)
    bottomPadding: Style.space(8)

    Item {
      width: parent.width
      height: Math.max(srLabel.implicitHeight, srValue.implicitHeight)
      Text {
        id: srLabel
        anchors.left: parent.left
        anchors.right: srValue.left
        anchors.rightMargin: Style.space(8)
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: sr.label
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
      }
      Text {
        id: srValue
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: sr.valueText
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
      }
    }
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: sr.description
      color: Util.alpha(Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    PanelSlider {
      width: parent.width
      value: sr.value
      minimum: sr.minimum
      maximum: sr.maximum
      step: sr.step
      integer: sr.integer
      trackColor: Util.alpha(Color.foreground, 0.18)
      fillColor: Color.accent
      knobColor: Color.foreground
      onMoved: (v) => sr.moved(v)
    }
  }

  component ChoiceRow: Column {
    id: cr
    property string label: ""
    property string description: ""
    property var options: []
    property string value: ""
    signal picked(string value)

    width: parent ? parent.width : 0
    spacing: Style.space(6)
    topPadding: Style.space(8)
    bottomPadding: Style.space(8)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: cr.label
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: cr.description
      color: Util.alpha(Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    ButtonGroup {
      options: cr.options
      value: cr.value
      onChanged: (value) => cr.picked(value)
    }
  }

  component SwitchRow: Toggle {
    property string path: ""
    width: parent ? parent.width : 0
    checked: sheet.cfg[path] === true
    onClicked: sheet.setValue(path, !checked)
  }

  Flickable {
    id: scroller
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: top.bottom
    anchors.bottom: parent.bottom
    anchors.leftMargin: sheet.pad
    anchors.rightMargin: sheet.pad
    anchors.topMargin: Style.space(12)
    anchors.bottomMargin: sheet.pad
    contentHeight: pages.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: pages
      width: scroller.width

      // ---- Gestos ----
      Column {
        width: parent.width
        visible: sheet.tab === "gestures"

        ChoiceRow {
          label: strings.t("gestures.fingers")
          description: strings.t("gestures.fingers.description")
          options: [{ value: "3", label: "3" }, { value: "4", label: "4" }]
          value: String(sheet.cfg.fingers)
          onPicked: (v) => sheet.setValue("fingers", Number(v))
        }
        PanelSeparator { width: parent.width }
        SwitchRow {
          path: "followFingers"
          label: strings.t("gestures.follow")
          description: strings.t("gestures.follow.description")
        }
        PanelSeparator { width: parent.width }
        SliderRow {
          label: strings.t("gestures.distance")
          description: strings.t("gestures.distance.description")
          valueText: strings.t("unit.px").arg(Math.round(sheet.cfg.swipeDistance))
          value: sheet.cfg.swipeDistance
          minimum: 150
          maximum: 600
          step: 10
          integer: true
          onMoved: (v) => sheet.setValue("swipeDistance", v)
        }
        PanelSeparator { width: parent.width }
        SwitchRow {
          path: "invertSideways"
          label: strings.t("gestures.invert")
          description: strings.t("gestures.invert.description")
        }
      }

      // ---- Apariencia ----
      Column {
        width: parent.width
        visible: sheet.tab === "look"

        SliderRow {
          label: strings.t("look.backdrop")
          valueText: strings.t("unit.percent").arg(Math.round(sheet.cfg.backdrop * 100))
          value: sheet.cfg.backdrop
          minimum: 0
          maximum: 1
          step: 0.02
          onMoved: (v) => sheet.setValue("backdrop", v)
        }
        PanelSeparator { width: parent.width }
        ChoiceRow {
          label: strings.t("look.corners")
          options: [{ value: "hyprland", label: strings.t("look.corners.hyprland") }, { value: "square", label: strings.t("look.corners.square") }]
          value: sheet.cfg.corners
          onPicked: (v) => sheet.setValue("corners", v)
        }
        PanelSeparator { width: parent.width }
        SliderRow {
          label: strings.t("look.spacing")
          valueText: strings.t("unit.px").arg(Math.round(sheet.cfg.spacing))
          value: sheet.cfg.spacing
          minimum: 8
          maximum: 48
          step: 2
          integer: true
          onMoved: (v) => sheet.setValue("spacing", v)
        }
        PanelSeparator { width: parent.width }
        SliderRow {
          label: strings.t("look.speed")
          description: strings.t("look.speed.description")
          valueText: strings.t("unit.times").arg(Number(sheet.cfg.animationSpeed).toFixed(1))
          value: sheet.cfg.animationSpeed
          minimum: 0.5
          maximum: 2
          step: 0.1
          onMoved: (v) => sheet.setValue("animationSpeed", Math.round(v * 10) / 10)
        }
        PanelSeparator { width: parent.width }
        SliderRow {
          label: strings.t("look.dockIcons")
          valueText: strings.t("unit.px").arg(Math.round(sheet.cfg.dockIconSize))
          value: sheet.cfg.dockIconSize
          minimum: 32
          maximum: 64
          step: 4
          integer: true
          onMoved: (v) => sheet.setValue("dockIconSize", v)
        }
      }

      // ---- Qué se muestra ----
      Column {
        width: parent.width
        visible: sheet.tab === "show"

        SwitchRow { path: "showStrip"; label: strings.t("show.strip"); description: strings.t("show.strip.description") }
        PanelSeparator { width: parent.width }
        SwitchRow { path: "showDock"; label: strings.t("show.dock"); description: strings.t("show.dock.description") }
        PanelSeparator { width: parent.width }
        SwitchRow { path: "showHints"; label: strings.t("show.hints"); description: strings.t("show.hints.description") }
        PanelSeparator { width: parent.width }
        SwitchRow { path: "showBadges"; label: strings.t("show.badges"); description: strings.t("show.badges.description") }
        PanelSeparator { width: parent.width }
        ChoiceRow {
          label: strings.t("show.dockClick")
          description: strings.t("show.dockClick.description")
          options: [{ value: "focus", label: strings.t("show.dockClick.focus") }, { value: "windows", label: strings.t("show.dockClick.windows") }]
          value: sheet.cfg.dockClick
          onPicked: (v) => sheet.setValue("dockClick", v)
        }
      }

      // ---- Atajos ----
      Column {
        width: parent.width
        visible: sheet.tab === "keys"
        spacing: 0

        KeyCapture {
          id: openRow
          width: parent.width
          mode: "combo"
          label: strings.t("keys.open")
          description: strings.t("keys.open.description")
          value: sheet.pendingBind !== "" ? sheet.pendingBind : sheet.cfg.openBind
          placeholder: strings.t("keys.press")
          invalidText: strings.t("keys.invalid.combo")
          warning: sheet.pendingConflict !== "" ? strings.t("keys.conflict").arg(sheet.pendingConflict) : ""
          onCaptured: (combo) => sheet.requestBind(combo)
        }

        // Taken combo: confirm or drop it.
        Row {
          visible: sheet.pendingBind !== ""
          spacing: Style.space(8)
          bottomPadding: Style.space(8)
          Button {
            text: strings.t("keys.useAnyway")
            onClicked: sheet.confirmBind()
          }
          Button {
            text: strings.t("keys.cancel")
            onClicked: sheet.cancelBind()
          }
        }

        Text {
          width: parent.width
          bottomPadding: Style.space(8)
          visible: text !== ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          text: sheet.hyprError !== "" ? strings.t("hypr.error").arg(sheet.hyprError)
            : !sheet.hyprIntegrated ? strings.t("hypr.missing")
            : ""
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width }
        KeyCapture {
          id: filterRow
          width: parent.width
          mode: "key"
          label: strings.t("keys.filter")
          value: sheet.cfg.keys ? sheet.cfg.keys.filter : ""
          placeholder: strings.t("keys.press")
          invalidText: strings.t("keys.invalid.key")
          onCaptured: (key) => sheet.setValue("keys.filter", key)
        }
        PanelSeparator { width: parent.width }
        KeyCapture {
          id: closeRow
          width: parent.width
          mode: "key"
          label: strings.t("keys.close")
          value: sheet.cfg.keys ? sheet.cfg.keys.close : ""
          placeholder: strings.t("keys.press")
          invalidText: strings.t("keys.invalid.key")
          onCaptured: (key) => sheet.setValue("keys.close", key)
        }
        PanelSeparator { width: parent.width }
        KeyCapture {
          id: settingsRow
          width: parent.width
          mode: "key"
          label: strings.t("keys.settings")
          value: sheet.cfg.keys ? sheet.cfg.keys.settings : ""
          placeholder: strings.t("keys.press")
          invalidText: strings.t("keys.invalid.key")
          onCaptured: (key) => sheet.setValue("keys.settings", key)
        }
        PanelSeparator { width: parent.width }
        ChoiceRow {
          label: strings.t("keys.send")
          description: strings.t("keys.send.description")
          options: [{ value: "SHIFT", label: "Shift" }, { value: "CTRL", label: "Ctrl" }, { value: "ALT", label: "Alt" }]
          value: sheet.cfg.sendModifier
          onPicked: (v) => sheet.setValue("sendModifier", v)
        }
      }
    }
  }
}
