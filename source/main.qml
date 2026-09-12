import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: win
    width: 1000
    height: 700
    minimumWidth: 560
    minimumHeight: 420
    visible: true
    title: "Disk Usage · btdu"

    // ------------------------------------------------------------- palette
    // Colors come from the active Omarchy theme (colors.toml), so the app
    // follows `omarchy theme set ...` just like the rest of the desktop.
    readonly property var themeVars: logic ? JSON.parse(logic.themeJson) : ({})
    function tc(key, fallback) {
        var v = themeVars[key];
        return (v === undefined || v === null) ? fallback : v;
    }
    readonly property color bg:       tc("background", "#1a1b26")
    readonly property color bgDeep:   tc("darker_background", "#0e0e14")
    readonly property color card:     tc("lighter_background", "#24283b")
    readonly property color fg:       tc("foreground", "#a9b1d6")
    readonly property color fgDim:    tc("dark_foreground", "#565f89")
    readonly property color fgBright: tc("bright_foreground", "#c0caf5")
    readonly property color accent:   tc("accent", "#7aa2f7")
    readonly property color cRed:     tc("red", "#f7768e")
    readonly property color cGreen:   tc("green", "#9ece6a")
    readonly property color cYellow:  tc("yellow", "#e0af68")
    readonly property color cMagenta: tc("magenta", "#ad8ee6")
    readonly property color cCyan:    tc("cyan", "#449dab")
    readonly property color sel:      tc("selection", "#292e42")
    readonly property string themeName: themeVars.__theme !== undefined ? themeVars.__theme : "unknown"

    font.family: "Noto Sans Mono"
    color: bg

    // ------------------------------------------------------------- data
    // Row geometry for the (currently inert) click probe (D reads this).
    property string rowMapJson: "[]"

    property var sum:    logic ? JSON.parse(logic.summaryJson || "{}") : ({})
    property var rows:   logic ? JSON.parse(logic.folderJson || "[]") : []
    property var crumbs: logic ? JSON.parse(logic.crumbsJson || "[]") : []
    property var mounts: logic ? JSON.parse(logic.mountsJson || "[]") : []
    property int sampleBudget: 200000

    // Advanced btdu options; applied to the controller with applyOpts(),
    // take effect on the next scan.
    property var opts: ({ physical: false, expert: true, seenAs: true,
                           seed: "", minRes: "", maxTime: "",
                           prefer: "", ignore: "" })
    function applyOpts() {
        if (logic)
            logic.setScanOptions(JSON.stringify(win.opts));
    }

    // Selection state (keyboard driven).
    property var selStack: []   // currentIndex per level, for Backspace restore
    property int pendingIndex: 0
    property var detail: ({ ok: false })
    property bool showDetail: true
    property string lastPhase: ""

    readonly property bool scanning: sum.phase === "sampling"
    readonly property string target: sum.scanPath || (mounts.length ? mounts[0].path : "/")
    readonly property bool typing: searchInput.activeFocus
        || optSeed.activeFocus || optMinRes.activeFocus || optMaxTime.activeFocus
        || optPrefer.activeFocus || optIgnore.activeFocus
    readonly property bool expertMode: sum.expert === true
    readonly property bool anyPopup: mountPopup.opened || depthPopup.opened
        || optsPopup.opened || helpPopup.opened

    function kindColor(k) {
        switch (k) {
        case "profile": return cMagenta;
        case "type":    return accent;
        case "unused":  return cYellow;
        case "deleted": return cRed;
        case "subvol":  return cCyan;
        case "dir":     return fgBright;
        default:        return fg;
        }
    }

    // --- keyboard navigation primitives. Model mutations are deferred
    // with Qt.callLater: never rebuild the list (destroying delegates)
    // while Qt Quick is still delivering the key event.
    function currentRowI() {
        var r = win.rows[list.currentIndex];
        return r ? r.i : -1;
    }
    function activateCurrent() {
        var disp = list.currentIndex;
        var r = win.rows[disp];
        if (!r || r.dir !== true)
            return;
        var i = r.i;
        Qt.callLater(function() {
            win.selStack.push(disp);
            win.pendingIndex = 0;
            logic.enter(i);
        });
    }
    function goUpKeep() {
        if (win.crumbs.length <= 1)
            return;
        var back = win.selStack.length ? win.selStack.pop() : 0;
        Qt.callLater(function() {
            win.pendingIndex = back;
            logic.goUp();
        });
    }
    function refreshDetail() {
        var i = currentRowI();
        if (i >= 0 && logic)
            win.detail = JSON.parse(logic.rowInfo(i) || '{"ok":false}');
        else
            win.detail = ({ ok: false });
    }
    function rescan() {
        Qt.callLater(function() {
            logic.startScan(win.target, win.sampleBudget);
        });
    }
    function focusList() {
        if (!win.typing && !win.anyPopup)
            list.forceActiveFocus();
    }

    onRowsChanged: {
        list.currentIndex = Math.max(0,
            Math.min(win.pendingIndex, win.rows.length - 1));
        refreshDetail();
    }
    onSumChanged: {
        // Move keyboard focus on phase transitions only.
        if (win.sum.phase !== win.lastPhase) {
            win.lastPhase = win.sum.phase;
            if (win.sum.ready)
                focusList();
            else if (win.sum.phase === "idle" && !win.sum.ready)
                ctaBtn.forceActiveFocus();
        }
    }

    // ------------------------------------------------------- tiny UI kit
    // NOTE: pointer activation and keyboard control coexist: every
    // control below is driven with Tab / arrows / Space / Enter, and
    // with the mouse. Model mutations from pointer handlers are
    // deferred with Qt.callLater (see README).
    component OmButton: Rectangle {
        id: btn
        property string text: ""
        property color textColor: win.fg
        property bool filled: false
        property color fillColor: win.accent
        property bool btnEnabled: true
        signal clicked()

        implicitWidth: Math.max(34, btnLabel.implicitWidth + 26)
        implicitHeight: 30
        radius: 8
        // Always a tab stop: switching activeFocusOnTab off while the
        // button is focused warns ("Cannot set activeFocusOnTab to false
        // once item is the active focus item"). Disabled buttons ignore
        // Space/Enter/clicks in the handlers below instead.
        activeFocusOnTab: true
        opacity: btn.btnEnabled ? 1 : 0.35
        color: btn.activeFocus ? (filled ? Qt.lighter(fillColor, 1.25) : win.sel)
                : filled ? (btnMouse.pressed ? Qt.lighter(fillColor, 1.15)
                           : btnMouse.containsMouse ? Qt.darker(fillColor, 1.1) : fillColor)
                : btnMouse.pressed ? Qt.lighter(win.card, 1.4)
                : btnMouse.containsMouse ? win.card : "transparent"
        border.width: btn.activeFocus ? 2 : 1
        border.color: btn.activeFocus ? win.accent
                      : filled ? "transparent" : Qt.alpha(win.fgDim, 0.45)
        Behavior on color { ColorAnimation { duration: 90 } }
        Keys.onPressed: (event) => {
            if (!btn.btnEnabled)
                return;
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter) {
                btn.clicked();
                event.accepted = true;
            }
        }

        Label {
            id: btnLabel
            anchors.centerIn: parent
            text: btn.text
            color: btn.filled ? win.bgDeep : btn.textColor
            font.pixelSize: 12
            font.bold: btn.filled
        }
        MouseArea {
            id: btnMouse
            anchors.fill: parent
            enabled: btn.btnEnabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    component OmCheck: Rectangle {
        id: chk
        property string text: ""
        property string hint: ""
        property bool checked: false
        signal toggled()

        implicitWidth: chkRow.implicitWidth + 20
        implicitHeight: 30
        radius: 8
        activeFocusOnTab: true
        color: chk.activeFocus ? win.sel
               : chkMouse.containsMouse ? Qt.alpha(win.sel, 0.5) : "transparent"
        border.width: chk.activeFocus ? 2 : 0
        border.color: win.accent
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter) {
                chk.toggled();
                event.accepted = true;
            }
        }
        MouseArea {
            id: chkMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chk.toggled()
        }

        RowLayout {
            id: chkRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10
            Rectangle {
                width: 15; height: 15; radius: 4
                color: chk.checked ? win.accent : "transparent"
                border.width: 1
                border.color: chk.checked ? win.accent : win.fgDim
                Label {
                    anchors.centerIn: parent
                    text: "✓"
                    visible: chk.checked
                    color: win.bgDeep
                    font.pixelSize: 11
                    font.bold: true
                }
            }
            Column {
                Layout.fillWidth: true
                spacing: 1
                Label { text: chk.text; color: win.fg; font.pixelSize: 12 }
                Label {
                    text: chk.hint; color: win.fgDim; font.pixelSize: 10
                    visible: chk.hint.length > 0
                }
            }
        }
    }

    component OmField: Rectangle {
        id: fld
        property string label: ""
        property string placeholder: ""
        property alias value: fldInput.text
        signal applied()

        implicitWidth: 260
        implicitHeight: fldCol.implicitHeight + 16
        radius: 8
        color: win.bgDeep
        border.width: fldInput.activeFocus ? 1 : 0
        border.color: Qt.alpha(win.accent, 0.6)
        Column {
            id: fldCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 8
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 2
            Label { text: fld.label; color: win.fgDim; font.pixelSize: 10 }
            TextInput {
                id: fldInput
                width: parent.width
                color: win.fg
                clip: true
                font.pixelSize: 12
                Keys.onReturnPressed: fld.applied()
                Keys.onEnterPressed: fld.applied()
            }
            Label {
                text: fld.placeholder
                color: win.fgDim
                font.pixelSize: 10
                font.italic: true
                visible: fldInput.text.length === 0
            }
        }
    }

    component OmTag: Rectangle {
        id: tag
        property string text: ""
        property color tagColor: win.accent
        implicitWidth: tagLabel.implicitWidth + 16
        implicitHeight: 20
        radius: 10
        color: "transparent"
        border.width: 1
        border.color: Qt.alpha(tag.tagColor, 0.6)
        Label {
            id: tagLabel
            anchors.centerIn: parent
            text: tag.text
            color: tag.tagColor
            font.pixelSize: 10
            font.bold: true
        }
    }

    component StatBlock: Column {
        id: stat
        property string label: ""
        // `var`, not `string`: the summary JSON omits keys per phase
        // (no `resolution` while idle, …) and assigning `undefined` to a
        // QString property warns. The fallback lives in the Text below.
        property var value: "—"
        spacing: 1
        Text { text: stat.label; color: win.fgDim; font.pixelSize: 10 }
        Text { text: stat.value === undefined ? "—" : stat.value; color: win.fgBright; font.pixelSize: 14; font.bold: true }
    }

    component FlowingBusy: Item {
        id: busy
        implicitWidth: 140
        implicitHeight: 6
        Rectangle {
            id: track
            anchors.fill: parent
            radius: 3
            color: Qt.alpha(win.fg, 0.08)
        }
        Rectangle {
            id: head
            width: 46
            height: busy.height
            radius: 3
            color: win.accent
            SequentialAnimation on x {
                loops: Animation.Infinite
                NumberAnimation { from: -head.width; to: track.width; duration: 1100; easing.type: Easing.InOutQuad }
            }
        }
    }

    component KeyRow: RowLayout {
        property string keys: ""
        property string action: ""
        spacing: 10
        Layout.fillWidth: true
        Label {
            text: keys
            color: win.accent
            font.pixelSize: 12
            font.bold: true
            Layout.preferredWidth: 130
        }
        Label {
            text: action
            color: win.fg
            font.pixelSize: 12
            Layout.fillWidth: true
            wrapMode: Label.WordWrap
        }
    }

    component OmPopup: Popup {
        parent: Overlay.overlay
        padding: 6
        modal: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle {
            radius: 10
            color: win.card
            border.color: Qt.alpha(win.fgDim, 0.5)
        }
    }

    // ------------------------------------------------------------ header
    header: Rectangle {
        color: win.bgDeep
        implicitHeight: headCol.implicitHeight

        ColumnLayout {
            id: headCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 14
                spacing: 10

                Rectangle { width: 12; height: 12; radius: 6; color: win.accent }
                Label {
                    text: "Disk Usage"
                    color: win.fgBright
                    font.pixelSize: 16
                    font.bold: true
                }
                OmTag { text: "btrfs · btdu"; tagColor: win.cMagenta }
                OmTag { text: "keys: ?"; tagColor: win.fgDim }
                Item { Layout.fillWidth: true }

                OmButton {
                    text: win.target
                    onClicked: mountPopup.open()
                }
                OmButton {
                    text: win.scanning ? "■ stop" : "⟳ scan"
                    filled: true
                    fillColor: win.scanning ? win.cRed : win.cGreen
                    onClicked: {
                        if (win.scanning)
                            logic.stopScan();
                        else {
                            applyOpts();
                            logic.startScan(win.target, win.sampleBudget);
                        }
                    }
                }
                OmButton {
                    text: Math.round(win.sampleBudget / 1000) + "k ▾"
                    onClicked: depthPopup.open()
                }
                OmButton {
                    text: "⚙"
                    onClicked: optsPopup.open()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 12
                spacing: 6

                OmButton {
                    text: "←"
                    btnEnabled: win.crumbs.length > 1
                    onClicked: goUpKeep()
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Repeater {
                        model: win.crumbs
                        delegate: RowLayout {
                            spacing: 0
                            Label {
                                text: " / "
                                color: win.fgDim
                                visible: index > 0
                                font.pixelSize: 12
                            }
                            OmButton {
                                text: modelData.label
                                textColor: index === win.crumbs.length - 1 ? win.fgBright : win.fgDim
                                onClicked: {
                                    var lvl = modelData.level;
                                    Qt.callLater(function() {
                                        win.selStack = win.selStack.slice(0, lvl);
                                        win.pendingIndex = 0;
                                        logic.goToLevel(lvl);
                                    });
                                }
                            }
                        }
                    }
                }
                Rectangle {
                    Layout.preferredWidth: 190
                    Layout.preferredHeight: 30
                    radius: 8
                    color: win.card
                    border.width: searchInput.activeFocus ? 1 : 0
                    border.color: Qt.alpha(win.accent, 0.6)
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 6
                        Label { text: "⌕"; color: win.fgDim }
                        TextInput {
                            id: searchInput
                            Layout.fillWidth: true
                            color: win.fg
                            clip: true
                            verticalAlignment: TextInput.AlignVCenter
                            font.pixelSize: 12
                            Keys.onEscapePressed: {
                                text = "";
                                focusList();
                            }
                            Text {
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                text: "filter…  ( / )"
                                color: win.fgDim
                                font.pixelSize: 12
                                visible: searchInput.text.length === 0 && !searchInput.activeFocus
                            }
                            onTextChanged: logic.setFilter(text)
                        }
                    }
                }
                OmButton {
                    id: sortBtn
                    property bool byName: false
                    text: byName ? "Aa ▾" : "size ▾"
                    onClicked: {
                        byName = !byName;
                        Qt.callLater(function() { logic.setSortByName(byName); });
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------- body
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // stats / sampling card
        Rectangle {
            Layout.fillWidth: true
            visible: win.sum.phase === "ready" || win.scanning
            radius: 12
            color: win.card
            border.color: Qt.alpha(win.fgDim, 0.3)
            border.width: 1
            implicitHeight: statsRow.implicitHeight + 24

            RowLayout {
                id: statsRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 18
                anchors.rightMargin: 18
                spacing: 26

                StatBlock { label: "used"; value: win.sum.usedText }
                StatBlock {
                    label: "samples"
                    value: win.sum.samples !== undefined ? win.sum.samples.toLocaleString() : "—"
                }
                StatBlock { label: "≈ resolution"; value: win.sum.resolution }
                StatBlock { label: "took"; value: win.sum.elapsed }
                StatBlock { label: "sampled at"; value: win.sum.fsPath }
                Item { Layout.fillWidth: true }
                OmTag {
                    text: "physical"
                    tagColor: win.cCyan
                    visible: win.sum.physical === true
                }
                OmTag {
                    text: "expert"
                    tagColor: win.cMagenta
                    visible: win.sum.expert === true
                }
                Column {
                    spacing: 5
                    visible: win.scanning
                    Text {
                        text: "sampling " + (win.sum.budget || 0).toLocaleString() + " points…"
                        color: win.cGreen
                        font.pixelSize: 12
                    }
                    FlowingBusy { width: 140 }
                }
            }
        }

        // error banner
        Rectangle {
            Layout.fillWidth: true
            visible: win.sum.phase === "error"
            radius: 12
            color: Qt.alpha(win.cRed, 0.10)
            border.color: Qt.alpha(win.cRed, 0.7)
            border.width: 1
            implicitHeight: errCol.implicitHeight + 26
            ColumnLayout {
                id: errCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 4
                Label { text: "btdu could not finish"; color: win.cRed; font.bold: true }
                Label {
                    text: win.sum.error || ""
                    color: win.fg
                    wrapMode: Label.WordWrap
                    Layout.fillWidth: true
                    font.pixelSize: 12
                }
                Label {
                    text: win.sum.log || ""
                    color: win.fgDim
                    visible: (win.sum.log || "").length > 0
                    elide: Label.ElideMiddle
                    Layout.fillWidth: true
                    font.pixelSize: 11
                }
            }
        }

        // call-to-action while nothing has been scanned yet
        Rectangle {
            id: ctaPanel
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: (win.sum.phase === "idle" || win.sum.phase === "error") && !win.sum.ready
            radius: 12
            color: win.card
            border.width: ctaBtn.activeFocus ? 2 : 0
            border.color: win.accent
            Column {
                anchors.centerIn: parent
                spacing: 16
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "how full is your btrfs, really?"
                    color: win.fgBright
                    font.pixelSize: 20
                    font.bold: true
                }
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 540
                    horizontalAlignment: Label.AlignHCenter
                    wrapMode: Label.WordWrap
                    text: "btdu samples random extents of the whole volume, so compressed, cloned and snapshot-shared data is counted exactly once — the numbers du(1) cannot give you. Needs root, asked via polkit."
                    color: win.fgDim
                    font.pixelSize: 12
                }
                Rectangle {
                    id: ctaBtn
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(230, ctaLabel.implicitWidth + 56)
                    height: 46
                    radius: 10
                    activeFocusOnTab: true
                    color: ctaMouse.pressed ? Qt.lighter(win.accent, 1.15)
                           : ctaMouse.containsMouse ? Qt.darker(win.accent, 1.1)
                           : ctaBtn.activeFocus ? Qt.lighter(win.accent, 1.25) : win.accent
                    border.width: ctaBtn.activeFocus ? 2 : 0
                    border.color: win.fgBright
                    Behavior on color { ColorAnimation { duration: 90 } }
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
                                || event.key === Qt.Key_Enter) {
                            applyOpts();
                            rescan();
                            event.accepted = true;
                        }
                    }
                    Label {
                        id: ctaLabel
                        anchors.centerIn: parent
                        text: "⟳  sample " + win.target + " now"
                        color: win.bgDeep
                        font.bold: true
                        font.pixelSize: 14
                    }
                    MouseArea {
                        id: ctaMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            applyOpts();
                            // Deferred like everywhere else: starting the
                            // scan swaps the CTA for the results card.
                            rescan();
                        }
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10
                    visible: win.mounts.length > 1
                    Repeater {
                        model: win.mounts
                        delegate: OmButton {
                            text: "scan " + modelData.path
                            onClicked: {
                                applyOpts();
                                Qt.callLater(function() {
                                    logic.startScan(modelData.path, win.sampleBudget);
                                });
                            }
                        }
                    }
                }
            }
        }

        // results list
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.sum.ready || win.scanning
            radius: 12
            color: win.card
            border.width: list.activeFocus ? 2 : 0
            border.color: win.accent

            Label {
                anchors.centerIn: parent
                visible: win.rows.length === 0
                text: win.scanning ? "collecting first samples…" : "nothing here"
                color: win.fgDim
            }

            ListView {
                id: list
                anchors.fill: parent
                anchors.margins: 8
                anchors.bottomMargin: win.showDetail && win.detail.ok ? 132 : 28
                clip: true
                model: win.rows
                focus: true
                activeFocusOnTab: true
                boundsBehavior: Flickable.StopAtBounds
                onCurrentIndexChanged: {
                    win.pendingIndex = list.currentIndex;
                    list.positionViewAtIndex(list.currentIndex, ListView.Contain);
                    refreshDetail();
                }
                Keys.onPressed: (event) => {
                    var n = list.count;
                    if (event.key === Qt.Key_Down) {
                        list.currentIndex = Math.min(n - 1, list.currentIndex + 1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        list.currentIndex = Math.max(0, list.currentIndex - 1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Home
                            || (event.key === Qt.Key_G && !(event.modifiers & Qt.ShiftModifier))) {
                        list.currentIndex = 0;
                        event.accepted = true;
                    } else if (event.key === Qt.Key_End
                            || (event.key === Qt.Key_G && (event.modifiers & Qt.ShiftModifier))) {
                        list.currentIndex = Math.max(0, n - 1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown) {
                        list.currentIndex = Math.min(n - 1, list.currentIndex + 12);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageUp) {
                        list.currentIndex = Math.max(0, list.currentIndex - 12);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Return
                            || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        activateCurrent();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backspace) {
                        goUpKeep();
                        event.accepted = true;
                    }
                }
                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    contentItem: Rectangle { radius: 3; color: Qt.alpha(win.fg, 0.25) }
                    background: Rectangle { color: "transparent" }
                }

                // Pointer handlers (not MouseArea): the Qt-recommended way
                // to combine taps with a Flickable (passive grabs, no
                // press stealing). Navigation is deferred with
                // Qt.callLater: never rebuild the list (destroying
                // delegates) while Qt Quick is still delivering the event.
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    property bool isDir: modelData.dir === true
                    property bool selected: index === list.currentIndex
                    width: list.width
                    height: rowCol.implicitHeight + 16
                    radius: 8
                    color: row.selected ? Qt.lighter(win.sel, 1.3)
                           : rowHover.hovered ? win.sel : "transparent"

                    HoverHandler { id: rowHover }
                    TapHandler {
                        onTapped: {
                            if (row.isDir) {
                                var disp = row.index;
                                var idx = row.modelData.i;
                                Qt.callLater(function() {
                                    win.selStack.push(disp);
                                    win.pendingIndex = 0;
                                    logic.enter(idx);
                                });
                            } else {
                                // Selecting never destroys delegates, and
                                // keeps the tapped file visible for scroll.
                                list.currentIndex = row.index;
                            }
                        }
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 3
                        radius: 1.5
                        color: win.kindColor(row.modelData.kind)
                        visible: row.selected
                    }

                    Column {
                        id: rowCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 12
                        anchors.rightMargin: 10
                        spacing: 4

                        RowLayout {
                            width: parent.width
                            spacing: 10
                            Label {
                                text: row.isDir ? "▸" : "·"
                                color: win.kindColor(row.modelData.kind)
                                font.bold: true
                                opacity: row.isDir ? 1 : 0.4
                            }
                            Label {
                                text: row.modelData.name
                                color: win.kindColor(row.modelData.kind)
                                font.bold: row.modelData.kind !== "file"
                                elide: Label.ElideMiddle
                                Layout.fillWidth: true
                            }
                            Label {
                                text: row.modelData.exclText || ""
                                color: win.fgDim
                                font.pixelSize: 10
                                visible: (row.modelData.exclText || "").length > 0
                            }
                            Label {
                                text: row.modelData.sharedText || ""
                                color: win.cCyan
                                font.pixelSize: 10
                                visible: (row.modelData.sharedText || "").length > 0
                            }
                            Label {
                                text: row.modelData.pct.toFixed(1) + "%"
                                color: win.fgDim
                                font.pixelSize: 11
                                Layout.preferredWidth: 48
                                horizontalAlignment: Label.AlignRight
                            }
                            Label {
                                text: row.modelData.sizeText
                                color: win.fgBright
                                Layout.preferredWidth: 92
                                horizontalAlignment: Label.AlignRight
                            }
                        }

                        Label {
                            text: row.modelData.desc || ""
                            visible: (row.modelData.desc || "").length > 0
                            color: win.fgDim
                            font.pixelSize: 11
                            font.italic: true
                            opacity: row.selected || rowHover.hovered ? 1 : 0.7
                            elide: Label.ElideRight
                            width: parent.width
                        }

                        // ncdu-style share-of-space bar; in expert mode the
                        // shared (CoW/snapshot) fraction gets its own segment
                        Rectangle {
                            width: parent.width
                            height: 5
                            radius: 2.5
                            color: Qt.alpha(win.fg, 0.07)
                            Rectangle {
                                width: parent.width * Math.min(1, row.modelData.pct / 100)
                                       * (1 - (row.modelData.ownPct !== undefined
                                               ? (100 - row.modelData.ownPct) / 100 : 0))
                                height: parent.height
                                radius: parent.radius
                                color: win.kindColor(row.modelData.kind)
                                opacity: 0.8
                            }
                            Rectangle {
                                anchors.right: parent.right
                                width: parent.width * Math.min(1, row.modelData.pct / 100)
                                       * (row.modelData.ownPct !== undefined
                                          ? (100 - row.modelData.ownPct) / 100 : 0)
                                height: parent.height
                                radius: parent.radius
                                color: win.cCyan
                                opacity: 0.8
                                visible: (row.modelData.ownPct || 100) < 100
                            }
                        }
                    }
                }
            }

            // details panel: own vs shared + seenAs attribution
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 8
                height: 112
                radius: 8
                color: win.bgDeep
                border.color: Qt.alpha(win.fgDim, 0.3)
                border.width: 1
                visible: win.showDetail && win.detail.ok === true
                clip: true
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 16
                    Column {
                        Layout.preferredWidth: 300
                        spacing: 2
                        Label {
                            text: win.detail.name || ""
                            color: win.fgBright
                            font.bold: true
                            font.pixelSize: 13
                            elide: Label.ElideMiddle
                            width: parent.width
                        }
                        Label {
                            text: { var t = (win.detail.kind || "");
                                    return t + " · " + (win.detail.sizeText || ""); }
                            color: win.fg
                            font.pixelSize: 11
                        }
                        Label {
                            text: { var o = (win.detail.ownText || "");
                                    var h = (win.detail.sharedText || "");
                                    return (o && h) ? o + " · " + h
                                         : (o || h || "represented size only (scan with expert mode for the own/shared split)"); }
                            color: win.cCyan
                            font.pixelSize: 11
                        }
                        Label {
                            text: win.detail.desc || ""
                            color: win.fgDim
                            font.pixelSize: 10
                            font.italic: true
                            elide: Label.ElideRight
                            width: parent.width
                        }
                    }
                    Column {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 2
                        Label {
                            text: "also stored under (shared extents — CoW clones / snapshots)"
                            color: win.fgDim
                            font.pixelSize: 10
                            visible: (win.detail.seenAs || []).length > 0
                        }
                        Repeater {
                            model: (win.detail.seenAs || []).slice(0, 4)
                            delegate: Label {
                                text: "≈" + modelData.pct.toFixed(1) + "% · "
                                      + modelData.sizeText + " · " + modelData.path
                                color: win.fg
                                font.pixelSize: 10
                                elide: Label.ElideMiddle
                                width: parent.width
                            }
                        }
                        Label {
                            text: "no other paths reference these extents"
                            color: win.fgDim
                            font.pixelSize: 10
                            font.italic: true
                            visible: (win.detail.seenAs || []).length === 0
                        }
                    }
                }
            }

            Label {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.margins: 10
                text: "largest 500 entries shown — refine with the filter"
                color: win.fgDim
                font.pixelSize: 10
                visible: win.rows.length >= 500
            }
        }
    }

    // ------------------------------------------------------------ footer
    footer: Rectangle {
        color: win.bgDeep
        height: 30
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 14
            Label { text: "theme: " + win.themeName; color: win.fgDim; font.pixelSize: 10 }
            Label {
                text: "↑↓/click select · →/Space open · ← up · / filter · o options · i details · ? keys"
                color: win.fgDim
                font.pixelSize: 10
            }
            Item { Layout.fillWidth: true }
            Label {
                text: win.sum.note || ""
                color: win.fgDim
                font.pixelSize: 10
                elide: Label.ElideMiddle
                Layout.maximumWidth: 420
            }
        }
    }

    // ------------------------------------------------------------ popups
    // All popups work with keyboard and mouse: arrows move, Enter/Space
    // picks, Escape closes; clicking a row picks it directly.
    // Model mutations stay deferred with Qt.callLater (see README).
    OmPopup {
        id: mountPopup
        x: Math.max(8, win.width - width - 20)
        y: 56
        onOpened: mountList.forceActiveFocus()
        onClosed: focusList()
        contentItem: ListView {
            id: mountList
            implicitWidth: 380
            implicitHeight: Math.min(count, 6) * 38
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            model: win.mounts
            currentIndex: 0
            highlight: Rectangle { radius: 7; color: win.sel }
            highlightFollowsCurrentItem: true
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Down) {
                    mountList.currentIndex = Math.min(mountList.count - 1, mountList.currentIndex + 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up) {
                    mountList.currentIndex = Math.max(0, mountList.currentIndex - 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    var m = win.mounts[mountList.currentIndex];
                    if (m) {
                        var p = m.path;
                        Qt.callLater(function() {
                            mountPopup.close();
                            applyOpts();
                            logic.startScan(p, win.sampleBudget);
                        });
                    }
                    event.accepted = true;
                }
            }
            delegate: Rectangle {
                id: mRow
                required property var modelData
                width: ListView.view.width
                height: 38
                radius: 7
                color: mMouse.containsMouse ? win.sel : "transparent"
                Label {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    elide: Label.ElideMiddle
                    text: mRow.modelData.label
                    color: win.fg
                    font.pixelSize: 12
                }
                MouseArea {
                    id: mMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        // Deferred: closing the popup + starting the scan
                        // must not run inside click delivery.
                        var p = mRow.modelData.path;
                        Qt.callLater(function() {
                            mountPopup.close();
                            applyOpts();
                            logic.startScan(p, win.sampleBudget);
                        });
                    }
                }
            }
        }
    }

    OmPopup {
        id: depthPopup
        x: Math.max(8, win.width - width - 20)
        y: 56
        onOpened: depthList.forceActiveFocus()
        onClosed: focusList()
        contentItem: ListView {
            id: depthList
            implicitWidth: 280
            implicitHeight: count * 34
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            model: [
                { label: "quick · 20k samples",     n: 20000 },
                { label: "standard · 200k samples", n: 200000 },
                { label: "accurate · 1M samples",   n: 1000000 },
                { label: "snooze · 10M samples",    n: 10000000 }
            ]
            currentIndex: 1
            highlight: Rectangle { radius: 7; color: win.sel }
            highlightFollowsCurrentItem: true
            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Down) {
                    depthList.currentIndex = Math.min(depthList.count - 1, depthList.currentIndex + 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up) {
                    depthList.currentIndex = Math.max(0, depthList.currentIndex - 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    var n = depthList.currentItem.modelData.n;
                    Qt.callLater(function() {
                        depthPopup.close();
                        win.sampleBudget = n;
                        applyOpts();
                        logic.startScan(win.target, n);
                    });
                    event.accepted = true;
                }
            }
            delegate: Rectangle {
                id: dRow
                required property var modelData
                property bool current: win.sampleBudget === modelData.n
                width: ListView.view.width
                height: 34
                radius: 7
                color: dMouse.containsMouse ? win.sel : "transparent"
                Label {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 10
                    text: (dRow.current ? "● " : "○ ") + dRow.modelData.label
                    color: dRow.current ? win.accent : win.fg
                    font.pixelSize: 12
                }
                MouseArea {
                    id: dMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        var n = dRow.modelData.n;
                        Qt.callLater(function() {
                            depthPopup.close();
                            win.sampleBudget = n;
                            applyOpts();
                            logic.startScan(win.target, n);
                        });
                    }
                }
            }
        }
    }

    // Advanced btdu options: the btrfs-specific knobs (physical space,
    // expert metrics, shared-path attribution, stop conditions, sampling
    // focus). Applied with logic.setScanOptions, take effect on next scan.
    OmPopup {
        id: optsPopup
        x: Math.max(8, win.width - width - 20)
        y: 56
        onClosed: focusList()
        contentItem: ColumnLayout {
            spacing: 4
            Label {
                text: "scan options — apply on next scan (r)"
                color: win.fgDim
                font.pixelSize: 11
            }
            OmCheck {
                text: "physical space  (-p)"
                hint: "on-disk bytes after CoW/compression instead of logical size"
                checked: win.opts.physical
                onToggled: { var o = win.opts; o.physical = !o.physical; win.opts = o; }
            }
            OmCheck {
                text: "expert metrics  (-x)"
                hint: "exclusive vs shared per row: what snapshots/CoW really cost"
                checked: win.opts.expert
                onToggled: { var o = win.opts; o.expert = !o.expert; win.opts = o; }
            }
            OmCheck {
                text: "shared-path attribution  (--export-seen-as)"
                hint: "record which other paths share each extent (details panel)"
                checked: win.opts.seenAs
                onToggled: { var o = win.opts; o.seenAs = !o.seenAs; win.opts = o; }
            }
            OmField {
                id: optSeed
                label: "seed (--seed)"
                placeholder: "empty = random each time"
                Component.onCompleted: value = win.opts.seed
            }
            OmField {
                id: optMinRes
                label: "stop at resolution (--min-resolution)"
                placeholder: 'e.g. "1%" or "10MiB"'
                Component.onCompleted: value = win.opts.minRes
            }
            OmField {
                id: optMaxTime
                label: "stop after (--max-time)"
                placeholder: 'e.g. "30s", "5m"'
                Component.onCompleted: value = win.opts.maxTime
            }
            OmField {
                id: optPrefer
                label: "focus sampling on (--prefer, comma separated)"
                placeholder: "e.g. @home — drops --auto-mount"
                Component.onCompleted: value = win.opts.prefer
            }
            OmField {
                id: optIgnore
                label: "skip while sampling (--ignore, comma separated)"
                placeholder: "e.g. @/.snapshots"
                Component.onCompleted: value = win.opts.ignore
            }
            RowLayout {
                spacing: 8
                OmButton {
                    text: "apply"
                    onClicked: {
                        var o = win.opts;
                        o.seed = optSeed.value;
                        o.minRes = optMinRes.value;
                        o.maxTime = optMaxTime.value;
                        o.prefer = optPrefer.value;
                        o.ignore = optIgnore.value;
                        win.opts = o;
                        applyOpts();
                        optsPopup.close();
                    }
                }
                OmButton {
                    text: "apply & rescan"
                    filled: true
                    onClicked: {
                        var o = win.opts;
                        o.seed = optSeed.value;
                        o.minRes = optMinRes.value;
                        o.maxTime = optMaxTime.value;
                        o.prefer = optPrefer.value;
                        o.ignore = optIgnore.value;
                        win.opts = o;
                        var t = win.target, b = win.sampleBudget;
                        Qt.callLater(function() {
                            optsPopup.close();
                            applyOpts();
                            logic.startScan(t, b);
                        });
                    }
                }
            }
        }
    }

    OmPopup {
        id: helpPopup
        x: (win.width - width) / 2
        y: (win.height - height) / 2
        onClosed: focusList()
        contentItem: ColumnLayout {
            spacing: 3
            Label { text: "keyboard"; color: win.fgBright; font.bold: true; font.pixelSize: 14 }
            KeyRow { keys: "Tab / Shift+Tab"; action: "move between controls" }
            KeyRow { keys: "↑ ↓ · PgUp PgDn · Home End"; action: "move the selection" }
            KeyRow { keys: "→ · Enter · Space"; action: "open the selected folder" }
            KeyRow { keys: "← · Backspace"; action: "go up one level" }
            KeyRow { keys: "g / G"; action: "first / last row" }
            KeyRow { keys: "/"; action: "filter the current level" }
            KeyRow { keys: "n"; action: "toggle size/name sort" }
            KeyRow { keys: "m · s · o"; action: "filesystem · sample depth · scan options" }
            KeyRow { keys: "i"; action: "toggle the own/shared details panel" }
            KeyRow { keys: "r"; action: "rescan" }
            KeyRow { keys: "Esc"; action: "close popup · leave the filter" }
            KeyRow { keys: "?"; action: "this help" }
            KeyRow { keys: "mouse"; action: "click a folder to open it, a file to select it" }
        }
    }

    // Row geometry export for the click-inertness probe.
    Timer {
        interval: 150
        running: true
        repeat: true
        onTriggered: {
            if (!list || list.count === 0) {
                win.rowMapJson = "[]";
                return;
            }
            var m = [];
            for (var i = 0; i < list.count; i++) {
                var it = list.itemAtIndex(i);
                if (!it)
                    continue;
                var c = it.mapToItem(null, 0, it.height / 2); // scene == window coords
                m.push({ i: i, x: c.x, y: c.y,
                         name: it.modelData ? it.modelData.name : "",
                         dir: it.modelData ? it.modelData.dir === true : false });
            }
            win.rowMapJson = JSON.stringify(m);
        }
    }

    // -------------------------------------------------------------- keys
    // Single-letter shortcuts stay quiet while typing in a field.
    Shortcut {
        sequence: "Backspace"
        enabled: !win.typing && !win.anyPopup
        onActivated: goUpKeep()
    }
    Shortcut {
        sequence: "r"
        enabled: !win.typing && !win.anyPopup
        onActivated: { applyOpts(); rescan(); }
    }
    Shortcut {
        sequence: "/"
        enabled: !win.anyPopup
        onActivated: searchInput.forceActiveFocus()
    }
    Shortcut {
        sequence: "n"
        enabled: !win.typing && !win.anyPopup
        onActivated: sortBtn.clicked()
    }
    Shortcut {
        sequence: "m"
        enabled: !win.typing && !win.anyPopup
        onActivated: mountPopup.open()
    }
    Shortcut {
        sequence: "s"
        enabled: !win.typing && !win.anyPopup
        onActivated: depthPopup.open()
    }
    Shortcut {
        sequence: "o"
        enabled: !win.typing && !win.anyPopup
        onActivated: optsPopup.open()
    }
    Shortcut {
        sequence: "i"
        enabled: !win.typing && !win.anyPopup
        onActivated: win.showDetail = !win.showDetail
    }
    Shortcut {
        sequence: "?"
        enabled: !win.typing && !win.anyPopup
        onActivated: helpPopup.open()
    }
    Shortcut {
        sequence: "F1"
        enabled: !win.anyPopup
        onActivated: helpPopup.open()
    }
    Shortcut {
        sequence: "Escape"
        enabled: !win.anyPopup
        onActivated: {
            if (win.typing) {
                searchInput.text = "";
                searchInput.focus = false;
                focusList();
            } else {
                focusList();
            }
        }
    }
}
