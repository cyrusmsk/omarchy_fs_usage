import QtQuick
import QtQuick.Controls

ApplicationWindow {
    id: win
    width: 800
    height: 600
    visible: true
    title: "minimal"
    color: "#1a1b26"

    property var rows: []

    ListView {
        id: list
        anchors.fill: parent
        clip: true
        model: win.rows
        boundsBehavior: Flickable.StopAtBounds
        delegate: Rectangle {
            width: list.width
            height: 60
            color: ma.pressed ? "#444" : "#333"
            Text { text: modelData.name; color: "#ccc" }
            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                onClicked: console.log("clicked", modelData.name)
            }
        }
    }

    Component.onCompleted: {
        var a = [];
        for (var i = 0; i < 30; i++)
            a.push({ name: "row " + i });
        win.rows = a;
    }
}
