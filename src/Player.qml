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

    // Frames were arriving and then stopped, while nothing reported an error. A
    // stream can wedge without the pipeline noticing: over UDP, lost packets can
    // corrupt a reference frame so the decoder rejects everything that follows,
    // while packets keep arriving normally, so neither the demuxer timeout nor the
    // player status ever changes. Only the absence of frames gives it away.
    readonly property alias stalled: d.stalled

    QtObject {
        id: d

        property bool firstFrameShown: false
        property bool stalled: false

        function frameArrived() {
            if (!firstFrameShown) {
                firstFrameShown = true;
            }

            stalled = false;
            // Only armed once frames have been seen, so this reports a stream that
            // died rather than one that has not started. A stream that never starts
            // is already covered by the status message.
            stallTimer.restart();
        }

        function reset() {
            firstFrameShown = false;
            stalled = false;
            stallTimer.stop();
        }
    }

    Timer {
        id: stallTimer

        // Far more generous before the first frame than after it. A stream that has
        // never delivered anything is usually just slow to connect, and 16 viewports
        // all flagging themselves for the first few seconds of every launch is the
        // fastest way to make the indicator worth ignoring. Once frames have been
        // seen, stopping is a real fault and worth reporting quickly.
        interval: d.firstFrameShown ? 4000 : 15000

        onTriggered: d.stalled = true
    }

    Timer {
        id: stallRecoveryTimer

        // Reconnects a stalled stream, and keeps trying while it stays stalled. The
        // interval is per attempt, so a genuinely dead camera retries at this rate
        // rather than hammering.
        interval: 6000
        repeat: true
        // Deliberately only for a stream that was working and stopped. That case has
        // nothing else watching it. A stream that has never delivered a frame is
        // already covered - demuxer_timeout gives up after 30s and QmlAVPlayer retries
        // on a terminal status - and reconnecting one that is merely slow to start
        // interrupts the connection it was in the middle of making.
        running: d.stalled && d.firstFrameShown && root.visible

        onTriggered: root.reconnect()
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
            d.reset();
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

                // Start watching for frames now rather than waiting for the first one,
                // so a stream that connects and then never decodes anything is still
                // reported. Skipped for an unconfigured viewport, which is empty on
                // purpose and says so through the status message.
                if (String(qmlAvPlayer.source) !== "") {
                    stallTimer.restart();
                }
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

            onSourceChanged: d.reset()
            onVideoFramePresented: d.frameArrived()

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

    // Tears the connection down and builds it again. QmlAVPlayer only reconnects by
    // itself when the demuxer reports a terminal status, which a stalled-but-still-
    // receiving stream never does.
    function reconnect() {
        qmlAvPlayer.stop();
        qmlAvPlayer.play();
    }

    function play() { qmlAvPlayer.play(); }
//    function pause() { mediaPlayer.pause(); }
//    function seek(position) { mediaPlayer.seek(position); }
    function stop() { qmlAvPlayer.stop(); }
}
