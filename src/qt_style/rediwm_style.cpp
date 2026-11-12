// RediWM's Qt style: Fusion, except that title bars use the window colour.
// Fusion fills an active title bar with the palette's Highlight (the theme
// accent). Chromium's Qt mode samples that title bar as its whole frame, so
// a following palette turned Brave's tab strip accent yellow.
// Built per Qt major against the system Qt (build/qt_style.zig).
#include <QPalette>
#include <QProxyStyle>
#include <QStyleFactory>
#include <QStyleOptionTitleBar>
#include <QStylePlugin>

namespace {

class Style : public QProxyStyle {
public:
    Style() : QProxyStyle(QStyleFactory::create(QStringLiteral("Fusion"))) {}

    void drawComplexControl(ComplexControl control, const QStyleOptionComplex *option, QPainter *painter,
                            const QWidget *widget) const override {
        const auto *bar = control == CC_TitleBar ? qstyleoption_cast<const QStyleOptionTitleBar *>(option) : nullptr;
        if (!bar) {
            QProxyStyle::drawComplexControl(control, option, painter, widget);
            return;
        }
        // Fusion draws an inactive bar from Window/WindowText; give the
        // active one the same colours so focus never paints the accent.
        QStyleOptionTitleBar neutral(*bar);
        neutral.palette.setColor(QPalette::Highlight, bar->palette.color(QPalette::Active, QPalette::Window));
        neutral.palette.setColor(QPalette::HighlightedText, bar->palette.color(QPalette::Active, QPalette::WindowText));
        QProxyStyle::drawComplexControl(control, &neutral, painter, widget);
    }
};

} // namespace

class RediwmStylePlugin : public QStylePlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QStyleFactoryInterface_iid FILE "rediwm_style.json")

public:
    QStyle *create(const QString &key) override {
        return key.compare(QLatin1String("RediWM"), Qt::CaseInsensitive) == 0 ? new Style : nullptr;
    }
};

#include "rediwm_style.moc"
