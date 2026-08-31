#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QTranslator>

#if defined(Q_OS_MACOS)
#include <QFontDatabase>
#endif

#include "qmlavplayer.h"
#include "context.h"
#include "eventfilter.h"
#include "clipboard.h"
#include "singleapplication.h"
#include "context.h"
#include "viewportslayoutscollectionmodel.h"

void registerQmlTypes()
{
    qmlRegisterSingletonType<Context>("CCTV_Viewer.Core", 1, 0, "Context",
                                      []([[maybe_unused]] QQmlEngine *engine,
                                         [[maybe_unused]] QJSEngine *scriptEngine) -> QObject * {
        return new Context();
    });
    qmlRegisterSingletonType<Clipboard>("CCTV_Viewer.Utils", 1, 0, "Clipboard",
                                                []([[maybe_unused]] QQmlEngine *engine,
                                                   [[maybe_unused]] QJSEngine *scriptEngine) -> QObject * {
                                                    return new Clipboard();
                                                });
    qmlRegisterSingletonType<SingleApplication>("CCTV_Viewer.Utils", 1, 0, "SingleApplication",
                                                []([[maybe_unused]] QQmlEngine *engine,
                                                   [[maybe_unused]] QJSEngine *scriptEngine) -> QObject * {
        return new SingleApplication();
    });

    qmlRegisterType<QmlAVPlayer>("CCTV_Viewer.Multimedia", 1, 0, "QmlAVPlayer");
    qmlRegisterType<ViewportsLayoutItem>("CCTV_Viewer.Models", 1, 0, "ViewportsLayoutItem");
    qmlRegisterType<ViewportsLayoutModel>("CCTV_Viewer.Models", 1, 0, "ViewportsLayoutModel");
    qmlRegisterType<ViewportsLayoutsCollectionModel>("CCTV_Viewer.Models", 1, 0, "ViewportsLayoutsCollectionModel");

    qmlRegisterType<EventFilter>("CCTV_Viewer.Utils", 1, 0, "EventFilter");
}

int main(int argc, char *argv[])
{
    QCoreApplication::setAttribute(Qt::AA_EnableHighDpiScaling);

#if defined(Q_OS_MACOS)
    // Load the macOS variant of the Quick Controls configuration, which omits the
    // fixed 10pt font so that controls inherit the system UI font set below.
    // Must happen before the Quick Controls plugin is loaded.
    qputenv("QT_QUICK_CONTROLS_CONF", ":/qtquickcontrols2-macos.conf");
#endif

#if defined(Q_OS_LINUX) && !defined(Q_OS_ANDROID)
    // The VA-API hardware-decode output module (QmlAVHWOutput_VAAPI_EGL) imports
    // a dma-buf as a texture via eglGetCurrentDisplay(), which only returns
    // something usable when Qt's own GL context is itself EGL-based. Qt 5's
    // default GL integration on X11 is GLX, so force EGL here, before
    // QGuiApplication exists - that construction is when the choice is made.
    // A no-op under Wayland, where this variable isn't consulted, and skipped
    // if the user (or session) already set one, so a deliberate override still
    // wins. See BUILD-linux.md §5.
    if (!qEnvironmentVariableIsSet("QT_XCB_GL_INTEGRATION")) {
        qputenv("QT_XCB_GL_INTEGRATION", "xcb_egl");
    }

    // Make the window identify itself as cctv-viewer, so desktop environments
    // can tie it to the launcher that started it. Without this the taskbar
    // entry is an unnamed generic window with no icon, because nothing it
    // reports matches StartupWMClass in cctv-viewer.desktop.
    //
    // The two platforms read different things and neither is interchangeable:
    //
    // X11 uses WM_CLASS, whose instance name Qt 5's xcb plugin takes from
    // `-name`, else RESOURCE_NAME, else the basename of argv[0] - and never
    // from setDesktopFileName(). Under an AppImage argv[0] is linuxdeploy's
    // AppRun.wrapped shim, so the pair came out "AppRun.wrapped"/"CCTV Viewer"
    // and matched nothing. Set only when unset, so an explicit `-name` (which
    // outranks it anyway) or a session-provided value still wins.
    //
    // Wayland ignores WM_CLASS entirely and keys off app_id, which is where
    // setDesktopFileName() does apply. Harmless on X11, so it is set
    // unconditionally rather than probed for at this point - the platform
    // plugin has not been chosen yet.
    if (!qEnvironmentVariableIsSet("RESOURCE_NAME")) {
        qputenv("RESOURCE_NAME", "cctv-viewer");
    }
    QGuiApplication::setDesktopFileName(QStringLiteral("cctv-viewer"));
#endif

#if defined(APP_NAME)
    QCoreApplication::setApplicationName(QLatin1String(APP_NAME));
#endif
#if defined(APP_VERSION)
    QCoreApplication::setApplicationVersion(QLatin1String(APP_VERSION));
#endif
#if defined(ORG_NAME)
    QCoreApplication::setOrganizationName(QLatin1String(ORG_NAME));
#endif
#if defined(ORG_DOMAIN)
    QCoreApplication::setOrganizationDomain(QLatin1String(ORG_DOMAIN));
#endif

    qInfo() << "CCTV Viewer version:" << APP_VERSION;

    registerQmlTypes();

    QGuiApplication app(argc, argv);

#if defined(Q_OS_MACOS)
    // Use the platform UI font (San Francisco at the system size) rather than
    // the fixed point size the Compact style specifies for other platforms.
    QGuiApplication::setFont(QFontDatabase::systemFont(QFontDatabase::GeneralFont));
#endif

    QQmlApplicationEngine engine;
    QTranslator translator;
    const QString locale = QLocale::system().name();
    translator.load(QLatin1String("cctv-viewer_") + locale, QLatin1String(":/translations/"));
    app.installTranslator(&translator);
    // The Dock, Finder and Cmd-Tab icon comes from the bundle's .icns on macOS
    // (CMakeLists.txt). setWindowIcon() would override it at runtime with
    // upstream's artwork, so the icon changed the moment the app launched.
#if !defined(Q_OS_MACOS)
    app.setWindowIcon(QIcon(QLatin1String(":/images/cctv-viewer.svg")));
#endif

    Context::init();

    engine.addImportPath(":/src/imports");
    const QUrl url(QStringLiteral("qrc:/src/RootWindow.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated, &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl)
            QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);
    engine.load(url);

    // NOTE: Debug
    // Testing Right-to-left User Interfaces...
    // (This code must be removed!!!)
//    QGuiApplication::setLayoutDirection(Qt::RightToLeft);

    return app.exec();
}
