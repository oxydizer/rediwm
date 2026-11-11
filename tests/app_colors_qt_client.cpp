// Read the platform plugin's real QPalette, including the Qt6 Accent role, and
// the frame colour Chromium's Qt mode derives from an active title bar.
#include <QApplication>
#include <QImage>
#include <QPainter>
#include <QPalette>
#include <QStyle>
#include <QStyleOptionTitleBar>
#include <QJsonDocument>
#include <QJsonObject>
#include <cstdio>

// As Chromium's QtShim::GetFrameColor: the style's active title bar, averaged.
static QString frame() {
    QImage image(32, 32, QImage::Format_ARGB32_Premultiplied);
    image.fill(qApp->palette().color(QPalette::Window));
    QPainter painter(&image);
    QStyleOptionTitleBar option;
    option.rect = QRect(-5, -5, 42, 42);
    option.titleBarState = QStyle::State_Active;
    qApp->style()->drawComplexControl(QStyle::CC_TitleBar, &option, &painter, nullptr);
    painter.end();
    long sum[3] = {0, 0, 0};
    for (int y = 0; y < image.height(); y++)
        for (int x = 0; x < image.width(); x++) {
            const QColor c = image.pixelColor(x, y);
            sum[0] += c.red(), sum[1] += c.green(), sum[2] += c.blue();
        }
    const long n = image.width() * image.height();
    return QColor(int(sum[0] / n), int(sum[1] / n), int(sum[2] / n)).name();
}

static void sample(const QPalette &p) {
    QJsonObject out{
        {"bg", p.color(QPalette::Window).name()},
        {"fg", p.color(QPalette::WindowText).name()},
        {"accent", p.color(QPalette::Highlight).name()},
        {"on_accent", p.color(QPalette::HighlightedText).name()},
        {"disabled", p.color(QPalette::Disabled, QPalette::WindowText).name()},
        {"style", QString::fromLatin1(qApp->style()->metaObject()->className())},
        {"frame", frame()}
    };
#if QT_VERSION >= QT_VERSION_CHECK(6, 6, 0)
    out.insert("qt6_accent", p.color(QPalette::Accent).name());
#endif
    std::puts(QJsonDocument(out).toJson(QJsonDocument::Compact).constData());
    std::fflush(stdout);
}

int main(int argc, char **argv) {
    QApplication app(argc, argv);
    sample(app.palette());
    if (app.arguments().contains("--watch")) {
        QObject::connect(&app, &QGuiApplication::paletteChanged, &app, sample);
        return app.exec();
    }
}
