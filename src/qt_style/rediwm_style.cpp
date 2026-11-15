// RediWM's Qt style: Fusion, except for title bars. Chromium's Qt mode
// samples a title bar as its whole frame, the tab strip, while its toolbar and
// active tab take the Button colour. Fusion fills an active title bar with the
// palette's Highlight (the theme accent), which turned a following Brave's tab
// strip accent yellow, and the Window colour alone sits too close to Button to
// show which tab is active. Title bars are therefore the Window colour moved
// kFrameDistance away from Button, the same rule as frame() in
// src/config/app_theme.zig, which colours Chromium's GTK frame.
// Chromium also draws much of its UI from its own light or dark scheme, so in
// a Chromium browser the palette is replaced by the colours RediWM exports for
// the light/dark preference (the `[Chromium]` group of the qt5ct/qt6ct scheme,
// `browserPalette` in app_theme.zig); other applications keep the scheme.
// Built per Qt major against the system Qt (build/qt_style.zig).
#include <QDir>
#include <QPalette>
#include <QProxyStyle>
#include <QSettings>
#include <QStyleFactory>
#include <QStyleOptionTitleBar>
#include <QStylePlugin>
#include <cmath>
#include <cstring>
#include <link.h>

namespace {

// L* between the frame and the toolbar (frame_distance in app_theme.zig).
constexpr double kFrameDistance = 14;

// CIE L*: 0 is black, 100 white.
double lightness(const QColor &c) {
    const auto linear = [](double v) { return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4); };
    const double y = 0.2126 * linear(c.redF()) + 0.7152 * linear(c.greenF()) + 0.0722 * linear(c.blueF());
    return y > 216.0 / 24389.0 ? 116 * std::cbrt(y) - 16 : y * 24389.0 / 27.0;
}

QColor mix(const QColor &target, const QColor &c, double amount) {
    const auto channel = [&](int t, int v) { return int(std::lround(t * amount + v * (1 - amount))); };
    return QColor(channel(target.red(), c.red()), channel(target.green(), c.green()), channel(target.blue(), c.blue()));
}

// Window, darkened until Button stands kFrameDistance above it (at most to
// black), or lightened when Button is too dark for even half of that.
QColor frameColor(const QPalette &palette) {
    const QColor window = palette.color(QPalette::Active, QPalette::Window);
    const double goal = lightness(palette.color(QPalette::Active, QPalette::Button));
    if (lightness(window) <= goal - kFrameDistance)
        return window;
    const bool darken = goal >= kFrameDistance / 2;
    const QColor target = darken ? QColor(0, 0, 0) : QColor(255, 255, 255);
    double low = 0, high = 1;
    for (int i = 0; i < 16; i++) {
        const double mid = (low + high) / 2;
        const double l = lightness(mix(target, window, mid));
        if (darken ? l <= goal - kFrameDistance : l >= goal + kFrameDistance)
            high = mid;
        else
            low = mid;
    }
    return mix(target, window, high);
}

// Chromium's Qt mode runs through libqt5_shim.so or libqt6_shim.so, which
// Chrome, Brave and the other Chromium browsers load before Qt itself.
bool inChromium() {
    return dl_iterate_phdr(
               [](dl_phdr_info *info, size_t, void *) {
                   const char *name = info->dlpi_name ? std::strrchr(info->dlpi_name, '/') : nullptr;
                   return name && (std::strcmp(name, "/libqt5_shim.so") == 0 || std::strcmp(name, "/libqt6_shim.so") == 0) ? 1 : 0;
               },
               nullptr) != 0;
}

// The scheme qt5ct or qt6ct loads, which RediWM writes while following.
QString schemePath() {
    QString config = qEnvironmentVariable("XDG_CONFIG_HOME");
    if (!QDir::isAbsolutePath(config))
        config = QDir::homePath() + QStringLiteral("/.config");
    const QString tool = QStringLiteral("qt%1ct").arg(QT_VERSION_MAJOR);
    return QSettings(config + QLatin1Char('/') + tool + QLatin1Char('/') + tool + QStringLiteral(".conf"), QSettings::IniFormat)
        .value(QStringLiteral("Appearance/color_scheme_path"))
        .toString();
}

// Roles in QPalette::ColorRole order, as qt5ct/qt6ct schemes list them.
void applyBrowserColors(QPalette &palette) {
    const QString path = schemePath();
    if (path.isEmpty())
        return;
    QSettings scheme(path, QSettings::IniFormat);
    const struct {
        const char *key;
        QPalette::ColorGroup group;
    } groups[] = {{"Chromium/active_colors", QPalette::Active},
                  {"Chromium/inactive_colors", QPalette::Inactive},
                  {"Chromium/disabled_colors", QPalette::Disabled}};
    for (const auto &g : groups) {
        const QStringList colors = scheme.value(QLatin1String(g.key)).toStringList();
        for (int role = 0; role < colors.size() && role < QPalette::NColorRoles; role++) {
            const QColor color(colors[role].trimmed());
            if (role != QPalette::NoRole && color.isValid())
                palette.setColor(g.group, QPalette::ColorRole(role), color);
        }
    }
}

class Style : public QProxyStyle {
public:
    Style() : QProxyStyle(QStyleFactory::create(QStringLiteral("Fusion"))), chromium_(inChromium()) {}

    using QProxyStyle::polish;
    void polish(QPalette &palette) override {
        QProxyStyle::polish(palette);
        if (chromium_)
            applyBrowserColors(palette);
    }

    void drawComplexControl(ComplexControl control, const QStyleOptionComplex *option, QPainter *painter,
                            const QWidget *widget) const override {
        const auto *bar = control == CC_TitleBar ? qstyleoption_cast<const QStyleOptionTitleBar *>(option) : nullptr;
        if (!bar) {
            QProxyStyle::drawComplexControl(control, option, painter, widget);
            return;
        }
        // Fusion fills an active bar with Highlight and an inactive one with
        // Window: both get the frame colour, so focus never paints the accent.
        QStyleOptionTitleBar neutral(*bar);
        const QColor frame = frameColor(bar->palette);
        neutral.palette.setColor(QPalette::Highlight, frame);
        neutral.palette.setColor(QPalette::Window, frame);
        neutral.palette.setColor(QPalette::HighlightedText, bar->palette.color(QPalette::Active, QPalette::WindowText));
        QProxyStyle::drawComplexControl(control, &neutral, painter, widget);
    }

private:
    const bool chromium_;
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
