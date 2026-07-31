import QtQml 2.12
import QtQuick 2.12
import QtMultimedia 5.12
import CCTV_Viewer.Multimedia 1.0

FocusScope {
    id: root

    property string color: "black"

    property var avOptions: ({})

    property alias loops: qmlAvPlayer.loops
    property alias source: qmlAvPlayer.source
    property alias muted: qmlAvPlayer.muted
    property alias volume: qmlAvPlayer.volume
    readonly property alias hasAudio: qmlAvPlayer.hasAudio
    readonly property alias status: qmlAvPlayer.status

    // True once this player has put a frame on screen, and false again whenever it
    // has nothing to show (new source, or stopped because it went invisible).
    //
    // Anything cross-fading two players has to wait on this rather than on
    // MediaPlayer.Buffered: the status reaches Buffered while the video surface is
    // still empty, so fading a player in on that signal fades in black.
    readonly property alias firstFrameShown: d.firstFrameShown

    QtObject {
        id: d

        property bool firstFrameShown: false
    }

    onVisibleChanged: {
        if (visible) {
            if (!timer.running) {
                timer.start();
            }
        } else {
            timer.stop();
            qmlAvPlayer.autoPlay = false;
            qmlAvPlayer.stop();
            d.firstFrameShown = false;
        }
    }
    Component.onCompleted: {
        if (visible) {
            timer.start();
        }
    }

    Timer {
        id: timer

        interval: 50

        onTriggered: {
            if (root.visible) {
                qmlAvPlayer.autoPlay = true;
            }
        }
    }

    Rectangle {
        color: root.color
        border.color: "#101010"
        anchors.fill: parent

        VideoOutput {
            id: videoOutput
            fillMode: VideoOutput.Stretch
            source: qmlAvPlayer
            anchors.fill: parent
        }

//        Rectangle {
//            id: shutter

//            color: root.color
//            visible: qmlAvPlayer.status !== MediaPlayer.Buffering && qmlAvPlayer.status !== MediaPlayer.Buffered
//            anchors.fill: parent
//        }

        Text {
            id: message

            color: "white"
            visible: qmlAvPlayer.status !== MediaPlayer.Buffered
            anchors.centerIn: parent
        }

        QmlAVPlayer {
            id: qmlAvPlayer

            autoLoad: false

            avOptions: {
                var avOptions = root.avOptions;

                // BUG: Без этого кода значения по умолчанию не устанавливаются. Это не должно происходить в коде плеера!
                Object.assignDefault(avOptions, layoutsCollectionSettings.toJSValue("defaultAVFormatOptions"));

                return avOptions;
            }

            onSourceChanged: d.firstFrameShown = false
            onVideoFramePresented: {
                if (!d.firstFrameShown) {
                    d.firstFrameShown = true;
                }
            }

            onStatusChanged: {
                switch (status) {
                case MediaPlayer.NoMedia:
                    message.text = qsTr("No media");
                    break;
                case MediaPlayer.Loading:
                    message.text = qsTr("Loading...");
                    break;
                case MediaPlayer.Loaded:
                    message.text = qsTr("Loaded");
                    break;
                case MediaPlayer.Buffering:
                    break;
                case MediaPlayer.Stalled:
                    message.text = qsTr("Stalled");
                    break;
                case MediaPlayer.Buffered:
                    break;
                case MediaPlayer.EndOfMedia:
                    message.text = qsTr("End of media");
                    break;
                case MediaPlayer.InvalidMedia:
                    message.text = qsTr("Error!");
                    break;
                case MediaPlayer.UnknownStatus:
                    break;
                }
            }

            onBufferProgressChanged: {
                message.text = qsTr("Buffering %1\%").arg(Math.round(bufferProgress * 100));
            }
        }
    }

    function play() { qmlAvPlayer.play(); }
//    function pause() { mediaPlayer.pause(); }
//    function seek(position) { mediaPlayer.seek(position); }
    function stop() { qmlAvPlayer.stop(); }
}
