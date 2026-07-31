import QtQml 2.12
import QtQuick 2.12
import QtQuick.Layouts 1.12
import QtMultimedia 5.12
import CCTV_Viewer.Core 1.0
import CCTV_Viewer.Utils 1.0
import CCTV_Viewer.Models 1.0

FocusScope {
    id: root

    property var size: model.size
    property var model: ViewportsLayoutModel {}
    property string color: "black"

    readonly property alias fullScreenIndex: d.fullScreenIndex
    readonly property alias focusIndex: d.focusIndex
    readonly property alias activeFocusIndex: d.activeFocusIndex
    readonly property alias pressAndHoldIndex: d.pressAndHoldIndex
    readonly property alias multiselect: d.multiselect

    onVisibleChanged: d.selectionReset()

    QtObject {
        id: d

        property real layoutRatio: (model.aspectRatio.width * model.size.width) / (model.aspectRatio.height * model.size.height);
        property int fullScreenIndex: -1
        property int focusIndex: -1
        property int activeFocusIndex: -1
        property int pressAndHoldIndex: -1
        property int selectionIndex1: focusIndex
        property int selectionIndex2
        property bool multiselect: selectionIndex2 != selectionIndex1
        property int keyModifiers: 0

        onLayoutRatioChanged: selectionReset()
        onSelectionIndex1Changed: selectionReset()

        function columnFromIndex(index) {
            return index % root.size.width;
        }

        function rowFromIndex(index) {
            return Math.floor(index / root.size.width);
        }

        function indexFromAddress(column, row) {
            return row * root.size.width + column;
        }

        function selectionTop() {
            var top1 = rowFromIndex(selectionIndex1);
            var top2 = rowFromIndex(selectionIndex2);

            return Math.min(top1, top2);
        }

        function selectionRight() {
            var item1 = root.get(selectionIndex1);
            var item2 = root.get(selectionIndex2);
            var right1 = columnFromIndex(selectionIndex1);
            var right2 = columnFromIndex(selectionIndex2);

            if (item1 !== undefined) {
                right1 += root.get(selectionIndex1).columnSpan;
            }
            if (item2 !== undefined) {
                right2 += root.get(selectionIndex2).columnSpan;
            }

            return Math.max(right1, right2);
        }

        function selectionBottom() {
            var item1 = root.get(selectionIndex1);
            var item2 = root.get(selectionIndex2);
            var bottom1 = rowFromIndex(selectionIndex1);
            var bottom2 = rowFromIndex(selectionIndex2);

            if (item1 !== undefined) {
                bottom1 += root.get(selectionIndex1).rowSpan;
            }
            if (item2 !== undefined) {
                bottom2 += root.get(selectionIndex2).rowSpan;
            }

            return Math.max(bottom1, bottom2);
        }

        function selectionLeft() {
            var left1 = columnFromIndex(selectionIndex1);
            var left2 = columnFromIndex(selectionIndex2);

            return Math.min(left1, left2);
        }

        function selectionWidth() {
            return selectionRight() - selectionLeft();
        }

        function selectionHeight() {
            return selectionBottom() - selectionTop();
        }

        function selectionContains(index) {
            var column = columnFromIndex(index);
            var row = rowFromIndex(index);

            if (get(index) !== undefined && get(index).visible &&
                    column >= selectionLeft() && column < selectionRight() &&
                    row >= selectionTop() && row < selectionBottom()) {
                return true;
            }

            return false;
        }

        function selectionReset() {
            selectionIndex2 = selectionIndex1;
        }
    }

    Rectangle {
        color: root.color
        anchors.fill: parent
    }

    GridLayout {
        id: layout

        width: (root.width / root.height <= d.layoutRatio) ? root.width : root.height * d.layoutRatio;
        height: (root.width / root.height < d.layoutRatio) ? root.width / d.layoutRatio : root.height;
        columns: root.size.width
        rows: root.size.height
        columnSpacing: 0
        rowSpacing: 0
        anchors.centerIn: parent

        Repeater {
            id: repeater

            model: root.model

            onCountChanged: {
                if (d.fullScreenIndex >= count) {
                    d.fullScreenIndex = -1;
                }
                if (d.focusIndex) {
                    if (count == 1) {
                        d.focusIndex = 0;
                    } else {
                        d.focusIndex = -1;
                    }
                }
                if (d.activeFocusIndex) {
                    d.activeFocusIndex = -1;
                }
                if (d.pressAndHoldIndex) {
                    d.pressAndHoldIndex = -1;
                }
            }

            delegate: Item {
                id: container

                implicitWidth: (layout.width / root.size.width) * Math.max(viewport.columnSpan, 0)
                implicitHeight: (layout.height / root.size.height) * Math.max(viewport.rowSpan, 0)
                visible: root.visible && ((model.visible === ViewportsLayoutItem.Visible) ? true : false)

                Layout.fillHeight: true
                Layout.fillWidth: true
                Layout.columnSpan: Math.max(viewport.columnSpan, 1);
                Layout.rowSpan: Math.max(viewport.rowSpan, 1);

                Item {
                    id: viewport

                    x: 0
                    y: 0
                    width: parent.width
                    height: parent.height
                    activeFocusOnTab: d.fullScreenIndex < 0 || d.fullScreenIndex === model.index

                    property int cursorColumnOffset: 0
                    property int cursorRowOffset: 0
                    property bool fullScreen: false
                    
                    // Zoom properties
                    property real zoomScale: 1.0
                    property real panX: 0
                    property real panY: 0
                    // True while the zoomed image is being dragged around.
                    property bool panning: false
                    // True when this viewport fills the whole layout, either because it was
                    // maximized or because the layout is a single cell.
                    readonly property bool maximized: fullScreen || (root.size.width === 1 && root.size.height === 1)
                    readonly property bool zoomEnabled: maximized

                    readonly property alias selected: d2.selected

                    readonly property alias url: d2.url
                    readonly property alias urlHigh: d2.urlHigh
                    readonly property bool hasHighStream: String(d2.urlHigh) !== ""
                    // Volume for whichever player is in front. Only one of the two is ever
                    // audible: both at once would double the audio during a handoff.
                    readonly property real playerVolume: Math.max(d2.volume,
                                                                  root.fullScreenIndex === index && viewportSettings.unmuteWhenFullScreen)
                    readonly property alias column: d2.column
                    readonly property alias row: d2.row
                    readonly property alias columnSpan: d2.columnSpan
                    readonly property alias rowSpan: d2.rowSpan
                    readonly property alias volume: d2.volume
                    readonly property alias avFormatOptions: d2.avFormatOptions

                    readonly property alias topIndex: d2.topIndex
                    readonly property alias rightIndex: d2.rightIndex
                    readonly property alias bottomIndex: d2.bottomIndex
                    readonly property alias leftIndex: d2.leftIndex

                    readonly property bool hasAudio: xfade.showHigh ? (xfade.highPlayer !== null && xfade.highPlayer.hasAudio)
                                                                   : player.hasAudio

                    states: [
                        State {
                            name: "fullScreen"
                            when: viewport.fullScreen

                            PropertyChanges {
                                target: viewport
                                // HACK: Вводим зависимость от размера container для того,
                                // чтобы инициировать пересчет позиции viewport при изменении размера GridLayout.
                                x: container.width ? -container.mapToItem(layout, 0, 0).x : 0
                                y: container.height ? -container.mapToItem(layout, 0, 0).y : 0
                                width: layout.width
                                height: layout.height
                            }
                            PropertyChanges {
                                target: viewport.parent
                                z: 1
                            }
                        }
                    ]

                    transitions: [
                        Transition {
                            ParallelAnimation {
                                PropertyAnimation {
                                    properties: "x, y, z, width, height"
                                    easing.type: Easing.Linear
                                    duration: 250
                                }
                            }
                        }
                    ]

                    onVisibleChanged: {
                        fullScreen = false;
                        resetZoom();
                        // Both players stop while the viewport is hidden, so on the way back
                        // neither has a picture. Put the base one in front: it is the lighter
                        // stream and will have something to show first. Otherwise a 1x1 preset -
                        // maximized by definition, so it stays on the high-quality stream -
                        // comes back to that player's "Loading..." instead.
                        xfade.showHigh = false;
                    }
                    onFullScreenChanged: {
                        d2.setCurrentIndex("fullScreenIndex", fullScreen)
                        if (!fullScreen) {
                            resetZoom();
                        }
                    }
                    onZoomEnabledChanged: {
                        if (!zoomEnabled) {
                            resetZoom();
                        }
                    }
                    onFocusChanged: {
                        d2.setCurrentIndex("focusIndex", focus);
                        d2.setCurrentIndex("pressAndHoldIndex", false);
                        fullScreen = false;
                    }
                    onActiveFocusChanged: d2.setCurrentIndex("activeFocusIndex", activeFocus)
                    onSelectedChanged: {
                        if (!selected) {
                            cursorColumnOffset = 0;
                            cursorRowOffset = 0;
                        }
                    }
                    onMaximizedChanged: maximizedSettleTimer.restart()
                    Component.onCompleted: {
                        // Seed the settled state instead of waiting for the timer, so a layout
                        // that starts out maximized (a 1x1 preset) begins loading its
                        // high-quality stream immediately.
                        xfade.maximizedSettled = maximized;
                    }

                    function resetZoom() {
                        zoomScale = 1.0;
                        panX = 0;
                        panY = 0;
                    }

                    // Cursor feedback for a drag in progress. These live on the viewport rather
                    // than in the MouseArea below because MouseArea has a cursorShape property
                    // of its own, which would shadow the window's CursorShape object and make
                    // "cursorShape.set" a call on an enum. Going through that object rather than
                    // setting MouseArea.cursorShape directly also leaves
                    // hideCursorWhenFullScreen working over the video.
                    function beginPan() {
                        panning = true;
                        cursorShape.set(Qt.ClosedHandCursor);
                    }

                    function endPan() {
                        if (panning) {
                            panning = false;
                            cursorShape.reset();
                        }
                    }

                    // Pan offsets run from 0 (image's left/top edge aligned with the viewport)
                    // down to width - width * zoomScale (right/bottom edge aligned), so they are
                    // zero or negative. Clamping to that range is what stops the image being
                    // dragged away from an edge and exposing background.
                    function setPan(x, y) {
                        panX = Number(x).clamp(width - width * zoomScale, 0);
                        panY = Number(y).clamp(height - height * zoomScale, 0);
                    }

                    Keys.onPressed: {
                        var fullScreenKey = QT_TR_NOOP("F", "Shortcut");
                        if (event.text.toUpperCase() === fullScreenKey ||
                            event.text.toUpperCase() === qsTr(fullScreenKey)) {
                            fullScreen = (root.size.width > 1 && root.size.height > 1) ? !fullScreen : false;
                            d.selectionReset();
                        }

                        function keyNavigationHandler(keyNavigationCallback) {
                            if (!fullScreen) {
                                if (d.activeFocusIndex >= 0 && d.keyModifiers & Qt.ShiftModifier) {
                                    d.selectionIndex2 = keyNavigationCallback(d.selectionIndex2);
                                } else {
                                    root.get(keyNavigationCallback(model.index)).forceActiveFocus();
                                }
                            }
                        }

                        switch (event.key) {
                        case Qt.Key_Escape:
                            focus = false;
                            fullScreen = false;
                            break;
                        case Qt.Key_Up:
                            function keyUpCallback(index) {
                                var topIndex = root.get(index).topIndex;

                                if (topIndex !== index) {
                                    root.get(topIndex).cursorColumnOffset =
                                            d.columnFromIndex(index) + root.get(index).cursorColumnOffset - d.columnFromIndex(topIndex);
                                } else {
                                    root.get(index).cursorRowOffset = Math.max(root.get(index).cursorRowOffset - 1, 0);
                                }

                                return topIndex;
                            }

                            keyNavigationHandler(keyUpCallback);
                            break;
                        case Qt.Key_Down:
                            function keyDownCallback(index) {
                                var bottomIndex = root.get(index).bottomIndex;

                                if (bottomIndex !== index) {
                                    root.get(bottomIndex).cursorColumnOffset =
                                            d.columnFromIndex(index) + root.get(index).cursorColumnOffset - d.columnFromIndex(bottomIndex);
                                } else {
                                    root.get(index).cursorRowOffset = Math.min(root.get(index).cursorRowOffset + 1, root.get(index).rowSpan - 1);
                                }

                                return bottomIndex;
                            }

                            keyNavigationHandler(keyDownCallback);
                            break;
                        case Qt.Key_Right:
                            function keyRightCallback(index) {
                                var rightIndex = root.get(index).rightIndex;

                                if (rightIndex !== index) {
                                    root.get(rightIndex).cursorRowOffset =
                                            d.rowFromIndex(index) + root.get(index).cursorRowOffset - d.rowFromIndex(rightIndex);
                                } else {
                                    root.get(index).cursorColumnOffset = Math.min(root.get(index).cursorColumnOffset + 1, root.get(index).columnSpan - 1);
                                }

                                return rightIndex;
                            }

                            keyNavigationHandler(keyRightCallback);
                            break;
                        case Qt.Key_Left:
                            function keyLeftCallback(index) {
                                var leftIndex = root.get(index).leftIndex;

                                if (leftIndex !== index) {
                                    root.get(leftIndex).cursorRowOffset =
                                            d.rowFromIndex(index) + root.get(index).cursorRowOffset - d.rowFromIndex(leftIndex);
                                } else {
                                    root.get(index).cursorColumnOffset = Math.max(root.get(index).cursorColumnOffset - 1, 0);
                                }

                                return leftIndex;
                            }

                            keyNavigationHandler(keyLeftCallback);
                            break;
                        }
                    }

                    QtObject {
                        id: d2

                        property bool selected: d.selectionContains(model.index)

                        property url url: model.url
                        property url urlHigh: model.urlHigh
                        property int column: d.columnFromIndex(model.index)
                        property int row: d.rowFromIndex(model.index)
                        property int columnSpan: model.columnSpan
                        property int rowSpan: model.rowSpan
                        property real volume: model.volume
                        property var avFormatOptions: model.avFormatOptions

                        property int topIndex: spanningIndex(viewport.column + viewport.cursorColumnOffset,
                                                             Number(viewport.row - 1).clamp(0, root.size.height - 1))

                        property int bottomIndex: spanningIndex(viewport.column + viewport.cursorColumnOffset,
                                                                Number(viewport.row + viewport.rowSpan).clamp(0, root.size.height - 1))

                        property int rightIndex: spanningIndex(Utils.ifLeftToRight(
                                                               Number(viewport.column + viewport.columnSpan).clamp(0, root.size.width - 1),
                                                               Number(viewport.column - 1).clamp(0, root.size.width - 1)),
                                                               viewport.row + viewport.cursorRowOffset)

                        property int leftIndex: spanningIndex(Utils.ifLeftToRight(
                                                              Number(viewport.column - 1).clamp(0, root.size.width - 1),
                                                              Number(viewport.column + viewport.columnSpan).clamp(0, root.size.width - 1)),
                                                              viewport.row + viewport.cursorRowOffset)

                        function setCurrentIndex(key, current) {
                            if (current === true) {
                                d[key] = model.index;
                            } else if (d[key] === model.index) {
                                d[key] = -1;
                            }
                        }

                        function spanningIndex(column, row) {
                            var spanningIndex = d.indexFromAddress(column, row);

                            if (spanningIndex !== model.index) {
                                var spanningItem = root.get(spanningIndex);

                                if (spanningItem !== undefined && !spanningItem.visible) {
                                    spanningIndex = d.indexFromAddress(d.columnFromIndex(spanningIndex) + spanningItem.columnSpan,
                                                                       d.rowFromIndex(spanningIndex) + spanningItem.rowSpan);
                                }
                            }

                            return spanningIndex;
                        }
                    }

                    // Cross-fade between the base and the high-quality stream.
                    //
                    // Changing a player's source tears the RTSP connection down and builds a
                    // new one, which takes seconds and puts "Loading..." on screen. So rather
                    // than one player swapping its source, two players overlap: the outgoing
                    // stream keeps rendering until the incoming one has put a frame on screen,
                    // and only then does the incoming one fade in over it. Once the fade has
                    // settled the player behind is stopped, so the steady state is still one
                    // stream per viewport.
                    //
                    // Each player's lifetime depends on the other one's readiness, which as a
                    // pair of bindings would be a loop - hence explicit state, reconciled in
                    // update().
                    QtObject {
                        id: xfade

                        // Debounced form of "maximized". Assigned only from the settle timer
                        // and Component.onCompleted, never bound.
                        property bool maximizedSettled: false

                        readonly property bool wantHigh: maximizedSettled && viewport.hasHighStream
                        readonly property var highPlayer: highPlayerLoader.item

                        // Loader.active for the high-quality player.
                        property bool highAlive: false
                        // Player.visible for the base player, which is what starts and stops
                        // its decoding.
                        property bool baseAlive: true
                        // Which of the two players is in front.
                        property bool showHigh: false

                        // Set when the high-quality stream is wanted but has not arrived in a
                        // reasonable time. Without some form of this, a mistyped high-quality
                        // URL is invisible: the base stream simply keeps playing.
                        property bool highSlow: false

                        readonly property bool highFailed: wantHigh && !showHigh &&
                                                           (highSlow ||
                                                            (highPlayer !== null &&
                                                             highPlayer.status === MediaPlayer.InvalidMedia))

                        onWantHighChanged: {
                            if (wantHigh) {
                                highLoadTimeout.restart();
                            } else {
                                highLoadTimeout.stop();
                                highSlow = false;
                            }

                            update();
                        }
                        onShowHighChanged: {
                            handoffTimer.restart();

                            if (showHigh) {
                                highLoadTimeout.stop();
                                highSlow = false;
                            }
                        }

                        function update() {
                            if (wantHigh) {
                                // Start the high-quality stream, and leave the base one in
                                // front until it has something to show.
                                highAlive = true;

                                if (highPlayer !== null && highPlayer.firstFrameShown) {
                                    showHigh = true;
                                }
                            } else {
                                // Bring the base stream back, holding the high-quality one in
                                // front until it has a frame of its own.
                                baseAlive = true;

                                if (player.firstFrameShown || !highAlive) {
                                    showHigh = false;
                                }
                            }

                            handoffTimer.restart();
                        }
                    }

                    Timer {
                        id: maximizedSettleTimer

                        // Longer than the 250ms maximize transition above, so a burst of
                        // double-clicks collapses into at most one stream change, and the new
                        // stream starts loading against a window that has stopped moving.
                        interval: 300

                        onTriggered: xfade.maximizedSettled = viewport.maximized
                    }

                    Timer {
                        id: handoffTimer

                        // Longer than the cross-fade below, so this only ever runs against a
                        // player that is fully hidden.
                        interval: 350

                        onTriggered: {
                            if (xfade.wantHigh) {
                                if (xfade.showHigh) {
                                    // High-quality stream is in front: stop the base one.
                                    xfade.baseAlive = false;
                                }
                            } else if (!xfade.showHigh) {
                                // Base stream is in front, so the high-quality player - which
                                // may never have become visible at all - can go.
                                xfade.highAlive = false;
                            }
                        }
                    }

                    Timer {
                        id: highLoadTimeout

                        // Generous on purpose: this only drives a message claiming the stream is
                        // unavailable, and a slow camera that does connect should never trip it.
                        interval: 15000

                        onTriggered: xfade.highSlow = true
                    }

                    Rectangle {
                        id: playerContainer

                        color: root.color
                        anchors.fill: parent
                        clip: true

                        // Zoom and pan act on both players at once, so they are applied to the
                        // stack rather than to either player.
                        Item {
                            id: playerStack

                            width: parent.width
                            height: parent.height

                            scale: viewport.zoomEnabled ? viewport.zoomScale : 1.0
                            transformOrigin: Item.TopLeft

                            x: viewport.zoomEnabled ? viewport.panX : 0
                            y: viewport.zoomEnabled ? viewport.panY : 0

                            Behavior on scale {
                                NumberAnimation { duration: 100; easing.type: Easing.OutQuad }
                            }
                            // Smooths the jump when zooming, but has to be out of the way while
                            // dragging: animating towards every intermediate mouse position
                            // makes the image lag behind the cursor and feel like it is sliding.
                            Behavior on x {
                                enabled: !viewport.panning
                                NumberAnimation { duration: 100; easing.type: Easing.OutQuad }
                            }
                            Behavior on y {
                                enabled: !viewport.panning
                                NumberAnimation { duration: 100; easing.type: Easing.OutQuad }
                            }

                            Player {
                                id: player

                                color: root.color
                                source: viewport.url
                                volume: xfade.showHigh ? 0 : viewport.playerVolume
                                avOptions: viewport.avFormatOptions
                                loops: MediaPlayer.Infinite
                                // Stops decoding once the high-quality stream is in front. Also
                                // reads false when the whole viewport is hidden, which is how
                                // hidden viewports have always stopped their players.
                                visible: xfade.baseAlive
                                anchors.fill: parent

                                onFirstFrameShownChanged: xfade.update()
                            }

                            Loader {
                                id: highPlayerLoader

                                active: xfade.highAlive
                                anchors.fill: parent
                                // Zero while it loads, so neither its black background nor its
                                // "Loading..." covers the stream still playing underneath.
                                opacity: xfade.showHigh ? 1 : 0

                                sourceComponent: Player {
                                    color: root.color
                                    source: viewport.urlHigh
                                    volume: xfade.showHigh ? viewport.playerVolume : 0
                                    avOptions: viewport.avFormatOptions
                                    loops: MediaPlayer.Infinite
                                    anchors.fill: parent

                                    onFirstFrameShownChanged: xfade.update()
                                }

                                Behavior on opacity {
                                    NumberAnimation { duration: 250; easing.type: Easing.InOutQuad }
                                }
                            }
                        }

                        Text {
                            id: highStreamWarning

                            text: qsTr("High-quality stream unavailable")
                            color: "white"
                            opacity: 0.7
                            visible: xfade.highFailed
                            font.pixelSize: 12
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.margins: 8
                        }
                    }

                    Rectangle {
                        id: selectionRect

                        color: "transparent"
                        anchors.fill: parent

                        states: [
                            State {
                                name: "multiselect"
                                when: root.multiselect && viewport.selected

                                PropertyChanges {
                                    target: selectionRect
                                    color: "#4000a8ff"
                                }
                            }
                        ]
                    }

                    Rectangle {
                        id: selectionFrame

                        color: "transparent"
                        border.color: "transparent"
                        anchors.fill: parent

                        states: [
                            State {
                                name: "active"
                                when: viewport.activeFocus && !Context.config.kioskMode

                                PropertyChanges {
                                    target: selectionFrame
                                    border.width: 1
                                    border.color: "#00dd00"
                                }
                            }
                        ]
                    }

                    MouseArea {
                        anchors.fill: parent
                        
                        // Enable wheel events for zooming
                        acceptedButtons: Qt.LeftButton

                        // Drag-to-pan state: where the press landed, and the pan offset it
                        // started from. The delta between them is applied on every move.
                        property real dragOriginX: 0
                        property real dragOriginY: 0
                        property real panOriginX: 0
                        property real panOriginY: 0

                        // Only a zoomed viewport has anywhere to pan to. Below 1.0 the clamp
                        // range in setPan() is empty, so claiming the drag would do nothing
                        // visible while taking the gesture away from selection.
                        readonly property bool canPan: viewport.zoomEnabled && viewport.zoomScale > 1.0

                        onPressed: {
                            if (d.activeFocusIndex >= 0 && d.keyModifiers & Qt.ShiftModifier) {
                                d.selectionIndex2 = model.index;
                            } else {
                                viewport.forceActiveFocus();
                                d.selectionReset();
                            }

                            if (canPan) {
                                dragOriginX = mouse.x;
                                dragOriginY = mouse.y;
                                panOriginX = viewport.panX;
                                panOriginY = viewport.panY;
                                viewport.beginPan();
                            }
                        }
                        onReleased: viewport.endPan()
                        onCanceled: viewport.endPan()
                        onPressAndHold: d2.setCurrentIndex("pressAndHoldIndex", true)
                        onDoubleClicked: {
                            viewport.fullScreen = (root.size.width > 1 && root.size.height > 1) ? !viewport.fullScreen : false;
                            d.selectionReset();
                        }

                        onMouseXChanged: mouseMoveHandler()
                        onMouseYChanged: mouseMoveHandler()
                        
                        // Handle mousewheel zoom when in fullscreen
                        onWheel: {

                                if (viewport.zoomEnabled) {
                                    var delta = wheel.angleDelta.y / 120;
                                    var zoomFactor = 1 + (delta * 0.1);

                                    var newScale = viewport.zoomScale * zoomFactor;
                                    newScale = Number(newScale).clamp(1.0, 10.0);

                                    if (newScale !== viewport.zoomScale) {
                                        var mouseX = wheel.x;
                                        var mouseY = wheel.y;

                                        var imageX = (mouseX - viewport.panX) / viewport.zoomScale;
                                        var imageY = (mouseY - viewport.panY) / viewport.zoomScale;

                                        viewport.zoomScale = newScale;

                                        // Keeps the point under the cursor fixed while the scale
                                        // changes, so the zoom tracks the mouse.
                                        viewport.setPan(mouseX - imageX * newScale,
                                                        mouseY - imageY * newScale);
                                    }
                                }

                                wheel.accepted = true;
                        }

                        function mouseMoveHandler() {
                            if (viewport.panning) {
                                viewport.setPan(panOriginX + (mouseX - dragOriginX),
                                                panOriginY + (mouseY - dragOriginY));
                                return;
                            }

                            if (!containsMouse) {
                                var selectionIndex2 = viewport.indexAt(mouseX, mouseY);

                                if (selectionIndex2 >= 0) {
                                    d.selectionIndex2 = selectionIndex2;
                                }
                            } else {
                                if (!(d.keyModifiers & Qt.ShiftModifier)) {
                                    d.selectionReset();
                                }
                            }
                        }
                    }

                    function indexAt(x, y) {
                        for (var i = 0; i < repeater.count; ++i) {
                            var itemTo = repeater.itemAt(i);

                            if (i === model.index) {
                                if (contains(Qt.point(x, y))) {
                                    return i;
                                }
                            } else {
                                var mappedPoint = mapToItem(itemTo, x, y);

                                if (itemTo.contains(mappedPoint)) {
                                    return i;
                                }
                            }
                        }

                        return -1;
                    }
                }
            }
        }
    }

    Keys.onPressed: {
        d.keyModifiers = event.modifiers;

        switch (event.key) {
        case Qt.Key_Delete:
            for (var i = 0; i < root.size.width * root.size.height; ++i) {
                if (root.get(i).selected) {
                    model.get(i).url = "";
                    model.get(i).urlHigh = "";
                    model.get(i).volume = 0;
                    model.get(i).avFormatOptions = layoutsCollectionSettings.toJSValue("defaultAVFormatOptions");
                }
            }
            break;
        }
    }
    Keys.onReleased: d.keyModifiers = event.modifiers

    function get(index) {
        if (index >= 0 && index < repeater.count) {
            var item = repeater.itemAt(index);
            if (item === null) {
                return undefined;
            }

            return item.children[0];
        }

        return;
    }

    function indexAt(x, y) {
        for (var i = 0; i < repeater.count; ++i) {
            var itemTo = repeater.itemAt(i);
            var mappedPoint = mapToItem(itemTo, x, y);

            if (itemTo.contains(mappedPoint)) {
                return i;
            }
        }

        return -1;
    }

    function mergeCells(testMode) {
        var topLeftIndex = d.indexFromAddress(d.selectionLeft(), d.selectionTop());
        if (topLeftIndex < 0 || topLeftIndex >= model.count) {
            return false;
        }
        var topLeftElement = model.get(topLeftIndex);

        if (d.selectionWidth() !== d.selectionHeight() ||
            d.selectionWidth() <= 0 || d.selectionHeight() <= 0 ||
            (d.selectionWidth() >= root.size.width && d.selectionHeight() >= root.size.height)) {
            return false;
        }

        if (!testMode) {
            if (topLeftElement.columnSpan > 1 || topLeftElement.rowSpan > 1) {
                topLeftElement.columnSpan = 1;
                topLeftElement.rowSpan = 1;
            } else {
                topLeftElement.columnSpan = d.selectionWidth();
                topLeftElement.rowSpan = d.selectionHeight();
            }

            d.selectionReset();
            model.normalize();
        }

        return true;
    }
}
