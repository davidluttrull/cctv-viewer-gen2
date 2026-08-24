//
// A throwaway measurement tool. It is not part of CCTV Viewer and nothing here
// is meant to survive into the port.
//
// It exists to answer one question before anyone spends weeks on a Qt 6
// migration: how many concurrent VideoToolbox decode sessions will iPadOS let
// one app hold open? The M1 iPad Pro has the raw throughput -- a 4x4 grid of
// 704x480 substreams is roughly 162 Mpixel/s, about two thirds of a single
// 4K30 stream, which an M1 media engine handles without noticing. What is not
// known is whether the system caps the *number* of sessions, because that is a
// policy and memory question rather than a silicon one, and a cap of 8 would
// change what the iPad version of this app can be.
//
// So: no Qt, no rendering, no UI to speak of. Open the real cameras from the
// real saved layout with the same FFmpeg options the macOS app uses, ramp the
// sessions up one at a time, and report exactly where it breaks. Decoded
// frames are counted and dropped; drawing them is the next question, not this
// one.
//
// The two axes that matter are set from the command line, which simctl passes
// through (see ios/make-probe.sh):
//
//     --sessions N   how many concurrent decoders to reach (default 16)
//     --ramp S       seconds between starting each one (default 2)
//     --nv12         leave VideoToolbox's default two-plane NV12 output alone
//                    instead of requesting BGRA
//
// --nv12 is worth running as a comparison. The app requests single-plane BGRA
// because the CoreVideo output module needs one texture per frame rather than
// one per plane, but that makes VideoToolbox do a colour conversion and makes
// every frame 4 bytes per pixel instead of 1.5. If a session ceiling turns out
// to be about memory, NV12 will show a different number, and that difference
// is worth knowing before it gets baked into the port.
//

#import <UIKit/UIKit.h>
#import <mach/mach.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/pixdesc.h>

#include <pthread.h>
#include <stdatomic.h>

#define MAX_SESSIONS 40

static int gTargetSessions = 16;
static double gRampSeconds = 2.0;
static BOOL gRequestBGRA = YES;

typedef enum {
    StatePending = 0,
    StateOpening,
    StateDecoding,
    StateFailed,
} SessionState;

typedef struct {
    int index;
    char host[80];
    char url[1200];

    atomic_int state;
    atomic_long frames;      // frames handed back by the decoder
    atomic_long hwFrames;    // arrived as a VideoToolbox CVPixelBuffer
    atomic_long swFrames;    // came back in system memory: hwaccel is not working
    atomic_long errors;
    atomic_long resyncs;     // decoder flushes after a damaged reference frame
    atomic_long dropped;     // packets discarded while waiting for a keyframe

    // Written by the worker thread, read by the UI timer without a lock. A
    // torn read would show one garbled line for half a second; taking a lock
    // per field in a measurement tool is not worth the ceremony.
    char status[200];

    double startedAt;
    double firstFrameAt;
    long lastFrames;         // UI-thread only, for the fps delta
    double fps;
    int width, height;
    int bgraGranted;         // -1 not attempted, 0 refused, 1 granted
} Session;

static Session gSessions[MAX_SESSIONS];
static int gSessionCount = 0;
static int gStarted = 0;
static double gProbeStart = 0;

static double nowSeconds(void)
{
    return CFAbsoluteTimeGetCurrent();
}

static void setStatus(Session *s, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s->status, sizeof(s->status), fmt, ap);
    va_end(ap);
}

static void failSession(Session *s, const char *what, int rc)
{
    char err[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(rc, err, sizeof(err));
    setStatus(s, "%s failed: %s (%d)", what, err, rc);
    atomic_store(&s->state, StateFailed);
    NSLog(@"PROBE session %d (%s) FAILED at %s: %s (%d)",
          s->index, s->host, what, err, rc);
}

// Resident footprint as iOS accounts for it -- the number that gets an app
// jetsammed, which is a plausible way for a session ceiling to show up.
static double footprintMB(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

static void requestBGRAFrames(AVCodecContext *ctx, Session *s);

// Insist on VideoToolbox. Silently accepting a CPU format would produce a
// probe that always "works" and measures nothing, so refuse instead and let
// the session fail loudly.
static enum AVPixelFormat pickHardwareFormat(AVCodecContext *ctx,
                                             const enum AVPixelFormat *formats)
{
    Session *s = ctx->opaque;
    for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            // The BGRA request belongs here, not next to avcodec_open2, and
            // this is not a style preference. avcodec_get_hw_frames_parameters()
            // is documented as "meant to get called from the get_format
            // callback"; on a context that has not reached that point it
            // dereferences null. Calling it before avcodec_open2 is what the
            // first version of this probe did, and every session died with
            // SIGSEGV at 0x70 about a second and a half in. qmlav gets this
            // right -- negotiatePixelFormatCb() calls requestBGRAHWFrames()
            // from inside the callback (qmlavdecoder.cpp:294) -- which is
            // another argument for mirroring the app rather than improvising.
            if (gRequestBGRA) {
                requestBGRAFrames(ctx, s);
            }
            return *p;
        }
    }
    setStatus(s, "decoder offered no videotoolbox format");
    return AV_PIX_FMT_NONE;
}

// Mirrors QmlAVVideoDecoder::requestBGRAHWFrames() in src/qmlav. Kept in step
// with it deliberately: a probe that configures VideoToolbox differently from
// the app measures a configuration nobody will ship. The colour-range dance is
// load-bearing -- FFmpeg registers BGRA under one range only, and a stream
// declaring the other range misses the lookup, at which point hwaccel init
// fails outright rather than falling back.
static void requestBGRAFrames(AVCodecContext *ctx, Session *s)
{
    if (!ctx->hw_device_ctx) {
        s->bgraGranted = 0;
        return;
    }

    const bool bgraAsFull = av_map_videotoolbox_format_from_pixfmt2(AV_PIX_FMT_BGRA, true) != 0;
    const bool bgraAsLimited = av_map_videotoolbox_format_from_pixfmt2(AV_PIX_FMT_BGRA, false) != 0;
    if (!bgraAsFull && !bgraAsLimited) {
        NSLog(@"PROBE this FFmpeg maps BGRA to no VideoToolbox format; leaving NV12");
        s->bgraGranted = 0;
        return;
    }

    const bool isFull = (ctx->color_range == AVCOL_RANGE_JPEG);
    const bool needFull = (isFull && bgraAsFull) || (!isFull && !bgraAsLimited);

    int rc = avcodec_get_hw_frames_parameters(ctx, ctx->hw_device_ctx,
                                              AV_PIX_FMT_VIDEOTOOLBOX,
                                              &ctx->hw_frames_ctx);
    if (rc < 0) {
        NSLog(@"PROBE session %d: hw frames parameters failed (%d), leaving NV12",
              s->index, rc);
        s->bgraGranted = 0;
        return;
    }

    AVHWFramesContext *frames = (AVHWFramesContext *)ctx->hw_frames_ctx->data;
    frames->sw_format = AV_PIX_FMT_BGRA;

    rc = av_hwframe_ctx_init(ctx->hw_frames_ctx);
    if (rc < 0) {
        NSLog(@"PROBE session %d: BGRA frames context init failed (%d), leaving NV12",
              s->index, rc);
        av_buffer_unref(&ctx->hw_frames_ctx);
        s->bgraGranted = 0;
        return;
    }

    if (needFull != isFull) {
        ctx->color_range = needFull ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
    }
    s->bgraGranted = 1;
}

static void *sessionWorker(void *arg)
{
    Session *s = (Session *)arg;
    s->startedAt = nowSeconds();
    atomic_store(&s->state, StateOpening);
    setStatus(s, "opening");

    AVDictionary *opts = NULL;
    // Straight out of defaultAVFormatOptions in the saved macOS layout, so
    // this stresses the same demuxer configuration the app will use. The
    // timeout is the one addition: without it a camera that stops answering
    // parks a thread forever and the probe reports a hang as a limit.
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "analyzeduration", "0", 0);
    av_dict_set(&opts, "probesize", "500000", 0);
    av_dict_set(&opts, "buffer_size", "2097152", 0);
    av_dict_set(&opts, "reorder_queue_size", "2000", 0);
    av_dict_set(&opts, "timeout", "8000000", 0);

    AVFormatContext *fmt = NULL;
    int rc = avformat_open_input(&fmt, s->url, NULL, &opts);
    av_dict_free(&opts);
    if (rc < 0) {
        failSession(s, "avformat_open_input", rc);
        return NULL;
    }

    rc = avformat_find_stream_info(fmt, NULL);
    if (rc < 0) {
        failSession(s, "avformat_find_stream_info", rc);
        avformat_close_input(&fmt);
        return NULL;
    }

    const AVCodec *decoder = NULL;
    int videoIndex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
    if (videoIndex < 0) {
        failSession(s, "av_find_best_stream", videoIndex);
        avformat_close_input(&fmt);
        return NULL;
    }

    AVCodecContext *ctx = avcodec_alloc_context3(decoder);
    if (!ctx) {
        failSession(s, "avcodec_alloc_context3", AVERROR(ENOMEM));
        avformat_close_input(&fmt);
        return NULL;
    }

    avcodec_parameters_to_context(ctx, fmt->streams[videoIndex]->codecpar);
    ctx->pkt_timebase = fmt->streams[videoIndex]->time_base;
    ctx->opaque = s;
    ctx->get_format = pickHardwareFormat;
    s->width = ctx->width;
    s->height = ctx->height;

    // One hw device context per session rather than a shared one, because that
    // is what the app does -- every QmlAVPlayer builds its own -- and if the
    // ceiling is per-device-context rather than per-decode-session, sharing
    // would hide it.
    AVBufferRef *hwDevice = NULL;
    rc = av_hwdevice_ctx_create(&hwDevice, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
    if (rc < 0) {
        failSession(s, "av_hwdevice_ctx_create", rc);
        avcodec_free_context(&ctx);
        avformat_close_input(&fmt);
        return NULL;
    }
    ctx->hw_device_ctx = av_buffer_ref(hwDevice);

    // bgraGranted stays -1 until get_format runs, which happens on the first
    // frame rather than during open.
    s->bgraGranted = -1;

    rc = avcodec_open2(ctx, decoder, NULL);
    if (rc < 0) {
        failSession(s, "avcodec_open2", rc);
        av_buffer_unref(&hwDevice);
        avcodec_free_context(&ctx);
        avformat_close_input(&fmt);
        return NULL;
    }

    atomic_store(&s->state, StateDecoding);
    setStatus(s, "opened %dx%d, awaiting first frame", s->width, s->height);
    NSLog(@"PROBE session %d (%s) opened: %dx%d %s",
          s->index, s->host, s->width, s->height, decoder->name);

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int sendErrors = 0;
    BOOL awaitingKeyFrame = NO;
    double lastProgress = nowSeconds();

    // Recovery, mirroring QmlAVDecoder::handleSendPacketError() in qmlav
    // (commit 4ad8a8f). It is not optional politeness: when packet loss
    // corrupts a reference frame, avcodec_send_packet returns the same error
    // for that frame and everything depending on it, and libavcodec has no way
    // back on its own. The first version of this probe simply counted 61
    // consecutive failures and declared the session dead, which failed 4 of 16
    // cameras -- all of which ffprobe opened fine one at a time. That was the
    // probe measuring its own missing resync, and on a device it would have
    // been read as an iPadOS session ceiling. The real app recovers here, so
    // the probe has to as well or its number means nothing.
    const int kResyncAfterSendErrors = 3;
    const long kMaxResyncs = 300;
    const double kNoProgressTimeout = 45.0;

    // The VideoToolbox session is not actually created until the first frame
    // is decoded, so a ceiling shows up here rather than at avcodec_open2 --
    // typically as AVERROR_EXTERNAL, or kVTVideoDecoderMalfunctionErr from
    // underneath. That is the whole reason this loop reports its errors
    // instead of quietly retrying forever.
    while (atomic_load(&s->state) == StateDecoding) {
        rc = av_read_frame(fmt, pkt);
        if (rc < 0) {
            if (rc == AVERROR(EAGAIN)) {
                continue;
            }
            failSession(s, "av_read_frame", rc);
            break;
        }

        if (pkt->stream_index != videoIndex) {
            av_packet_unref(pkt);
            continue;
        }

        // Drop everything until the stream can be picked up cleanly again.
        // Video only: inter-frame dependencies are the whole reason this is
        // needed, and audio packets are self-contained.
        if (awaitingKeyFrame && !(pkt->flags & AV_PKT_FLAG_KEY)) {
            atomic_fetch_add(&s->dropped, 1);
            av_packet_unref(pkt);
            if (nowSeconds() - lastProgress > kNoProgressTimeout) {
                failSession(s, "no keyframe to resync on", AVERROR_INVALIDDATA);
                break;
            }
            continue;
        }
        awaitingKeyFrame = NO;

        rc = avcodec_send_packet(ctx, pkt);
        av_packet_unref(pkt);
        if (rc < 0 && rc != AVERROR(EAGAIN)) {
            atomic_fetch_add(&s->errors, 1);
            if (++sendErrors >= kResyncAfterSendErrors) {
                // A single failure before the first keyframe is normal, which
                // is why this waits for three.
                avcodec_flush_buffers(ctx);
                awaitingKeyFrame = YES;
                sendErrors = 0;
                if (atomic_fetch_add(&s->resyncs, 1) + 1 > kMaxResyncs) {
                    failSession(s, "unrecoverable: resync limit reached", rc);
                    break;
                }
            }
            continue;
        }
        sendErrors = 0;

        // Liveness is judged on decoded frames, not packets: a camera with a
        // long keyframe interval can legitimately spend seconds mid-resync.
        if (atomic_load(&s->frames) == 0 &&
            nowSeconds() - s->startedAt > kNoProgressTimeout) {
            failSession(s, "opened but produced no frame", AVERROR_INVALIDDATA);
            break;
        }

        while (rc >= 0) {
            rc = avcodec_receive_frame(ctx, frame);
            if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) {
                break;
            }
            if (rc < 0) {
                // Receive-side errors get the same treatment as send-side
                // ones: flush and wait for a keyframe rather than giving up.
                atomic_fetch_add(&s->errors, 1);
                avcodec_flush_buffers(ctx);
                awaitingKeyFrame = YES;
                if (atomic_fetch_add(&s->resyncs, 1) + 1 > kMaxResyncs) {
                    failSession(s, "unrecoverable: resync limit reached", rc);
                }
                break;
            }

            lastProgress = nowSeconds();
            if (atomic_fetch_add(&s->frames, 1) == 0) {
                s->firstFrameAt = nowSeconds();
                // Only now is the negotiated format known: get_format runs on
                // the first frame, so this is the earliest point at which the
                // BGRA request has an answer.
                setStatus(s, "decoding %dx%d %s", s->width, s->height,
                          !gRequestBGRA ? "nv12"
                              : (s->bgraGranted == 1 ? "bgra" : "bgra-refused"));
                NSLog(@"PROBE session %d (%s) first frame after %.1fs, bgra=%d, fmt=%s",
                      s->index, s->host, s->firstFrameAt - s->startedAt,
                      s->bgraGranted, av_get_pix_fmt_name(frame->format));
            }

            // data[3] carries the CVPixelBufferRef. Counting this separately
            // from the frame total is what distinguishes real hardware decode
            // from a silent CPU fallback that would make the whole
            // measurement meaningless.
            if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->data[3]) {
                atomic_fetch_add(&s->hwFrames, 1);
            } else {
                atomic_fetch_add(&s->swFrames, 1);
            }

            av_frame_unref(frame);
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    av_buffer_unref(&hwDevice);
    avformat_close_input(&fmt);
    return NULL;
}

static void startNextSession(void)
{
    if (gStarted >= gTargetSessions || gSessionCount == 0) {
        return;
    }

    Session *s = &gSessions[gStarted];
    gStarted++;

    pthread_t tid;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&tid, &attr, sessionWorker, s) != 0) {
        setStatus(s, "pthread_create failed");
        atomic_store(&s->state, StateFailed);
    }
    pthread_attr_destroy(&attr);
}

#pragma mark - UI

@interface ProbeViewController : UIViewController
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation ProbeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.label = [[UILabel alloc] initWithFrame:CGRectZero];
    self.label.numberOfLines = 0;
    self.label.textColor = UIColor.greenColor;
    self.label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.label];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.label.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.label.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.label.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
    ]];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(refresh)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)refresh
{
    double uptime = nowSeconds() - gProbeStart;
    int open = 0, failed = 0, pending = 0;
    double totalFps = 0;
    long totalSW = 0;

    NSMutableString *text = [NSMutableString string];

    for (int i = 0; i < gStarted; i++) {
        Session *s = &gSessions[i];
        long frames = atomic_load(&s->frames);
        s->fps = (double)(frames - s->lastFrames);
        s->lastFrames = frames;

        SessionState state = atomic_load(&s->state);
        const char *tag = "?";
        switch (state) {
            case StatePending:  tag = "..."; pending++; break;
            case StateOpening:  tag = "OPN"; pending++; break;
            case StateDecoding: tag = "DEC"; open++; break;
            case StateFailed:   tag = "ERR"; failed++; break;
        }
        totalFps += s->fps;
        totalSW += atomic_load(&s->swFrames);

        [text appendFormat:@"%2d %-15s %s %5.1ffps %7ld f %7ld hw %5ld sw %4ld err %3ld rsy %5ld drp  %s\n",
            s->index, s->host, tag, s->fps, frames,
            atomic_load(&s->hwFrames), atomic_load(&s->swFrames),
            atomic_load(&s->errors), atomic_load(&s->resyncs),
            atomic_load(&s->dropped), s->status];
    }

    NSString *header = [NSString stringWithFormat:
        @"sessions %d/%d   decoding %d  failed %d  starting %d\n"
         "aggregate %.0f fps   footprint %.0f MB   %@   up %.0fs\n"
         "%@\n\n",
        gStarted, gTargetSessions, open, failed, pending,
        totalFps, footprintMB(),
        gRequestBGRA ? @"bgra" : @"nv12", uptime,
        totalSW > 0 ? @"WARNING: frames arriving in system memory -- hwaccel is NOT active"
                    : @"all frames are VideoToolbox CVPixelBuffers"];

    self.label.text = [header stringByAppendingString:text];

    // One greppable line per refresh, so the run can be read back from the
    // console log without anyone having to watch the screen.
    NSLog(@"PROBE started=%d decoding=%d failed=%d fps=%.0f footprint=%.0fMB sw=%ld up=%.0fs",
          gStarted, open, failed, totalFps, footprintMB(), totalSW, uptime);

    if (gStarted < gTargetSessions && uptime > (gStarted * gRampSeconds)) {
        startNextSession();
    }
}

@end

#pragma mark - Boot

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)options
{
    // Without this the screen sleeps mid-run and the measurement stops being
    // about decoding.
    application.idleTimerDisabled = YES;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ProbeViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

static void parseArguments(void)
{
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    for (NSUInteger i = 1; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:@"--sessions"] && i + 1 < args.count) {
            gTargetSessions = MIN(MAX_SESSIONS, MAX(1, args[++i].intValue));
        } else if ([a isEqualToString:@"--ramp"] && i + 1 < args.count) {
            gRampSeconds = MAX(0.0, args[++i].doubleValue);
        } else if ([a isEqualToString:@"--nv12"]) {
            gRequestBGRA = NO;
        }
    }
}

static void loadStreams(void)
{
    NSURL *url = [NSBundle.mainBundle URLForResource:@"streams" withExtension:@"json"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) {
        NSLog(@"PROBE FATAL no streams.json in the bundle -- run ios/probe/make-streams.sh");
        return;
    }

    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSArray *streams = root[@"streams"];

    // Cycle the list when more sessions are asked for than there are cameras.
    // Opening the same camera twice is a perfectly good session-count test,
    // and it is the only way to probe past 16 with 16 cameras -- though a
    // failure past that point could equally be the camera refusing a second
    // connection, so read those runs with care.
    for (int i = 0; i < gTargetSessions && streams.count > 0; i++) {
        NSDictionary *entry = streams[i % streams.count];
        Session *s = &gSessions[gSessionCount];
        s->index = gSessionCount;
        atomic_store(&s->state, StatePending);
        s->bgraGranted = -1;
        strncpy(s->host, [entry[@"host"] UTF8String] ?: "?", sizeof(s->host) - 1);
        strncpy(s->url, [entry[@"url"] UTF8String] ?: "", sizeof(s->url) - 1);
        setStatus(s, "queued");
        gSessionCount++;
    }

    NSLog(@"PROBE loaded %d sessions from %lu cameras, target %d, ramp %.1fs, %s",
          gSessionCount, (unsigned long)streams.count, gTargetSessions, gRampSeconds,
          gRequestBGRA ? "bgra" : "nv12");
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        parseArguments();

        av_log_set_level(AV_LOG_WARNING);
        avformat_network_init();

        loadStreams();
        gProbeStart = nowSeconds();
        startNextSession();

        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([ProbeAppDelegate class]));
    }
}
