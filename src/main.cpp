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
    app.setWindowIcon(QIcon(QLatin1String(":/images/cctv-viewer.svg")));

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
