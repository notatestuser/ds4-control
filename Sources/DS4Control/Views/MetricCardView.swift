import SwiftUI

struct MetricCardView: View {
    let title: String
    let icon: String
    let value: String
    let subtitle: String
    let severity: MetricSeverity
    let sparklineData: [(Date, Double)]
    var accentColor: Color = .blue
    var sparklineFixedRange: (min: Double, max: Double)? = nil
    var sparklineTimeRangeSeconds: TimeInterval? = nil
    var sparklineValueFormatter: ((Double) -> String)? = nil
    var details: [(label: String, value: String, color: Color?)] = []
    var emphasized: Bool = false
    /// Hides detail rows and shrinks the sparkline for a denser layout.
    var compact: Bool = false
    /// 0.0–1.0 fill for the inline gauge that replaces the header icon. When
    /// nil the plain SF Symbol icon is shown instead.
    var gaugeFraction: Double? = nil
    /// Overrides the severity-derived tint for this card (gauge, dot, sparkline,
    /// border). Lets the memory card read as yellow — not danger-red — at peak.
    var severityColorOverride: Color? = nil

    private var valueFontSize: CGFloat { emphasized ? 30 : 22 }
    private var sparklineHeight: CGFloat {
        if emphasized { return 48 }
        return compact ? 22 : 28
    }
    private var titleFontSize: CGFloat { emphasized ? 13 : 11 }
    private var iconFontSize: CGFloat { emphasized ? 15 : 13 }
    private var borderOpacity: Double { emphasized ? 0.45 : 0.15 }
    private var borderWidth: CGFloat { emphasized ? 1.5 : 1 }
    private var showDetails: Bool { !compact && !details.isEmpty }
    private var tint: Color { severityColorOverride ?? severity.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row: icon + title + severity dot
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: iconFontSize, weight: .semibold))
                    .foregroundStyle(accentColor)

                Text(title)
                    .font(.system(size: titleFontSize, weight: emphasized ? .semibold : .medium))
                    .foregroundStyle(emphasized ? .primary : .secondary)

                Spacer()

                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }

            // Value + subtitle on one row. When a gauge fraction is provided
            // (percentage-based widgets), the value is wrapped in a ring gauge.
            HStack(alignment: .center, spacing: 10) {
                if let fraction = gaugeFraction {
                    ValueGaugeView(
                        fraction: fraction,
                        text: value,
                        textFontSize: valueFontSize,
                        trackColor: tint,
                        diameter: emphasized ? 78 : 60
                    )
                } else {
                    Text(value)
                        .font(.system(size: valueFontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                Text(subtitle)
                    .font(.system(size: emphasized ? 11 : 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            // Sparkline
            SparklineView(
                dataPoints: sparklineData, lineColor: tint, fixedRange: sparklineFixedRange,
                timeRangeSeconds: sparklineTimeRangeSeconds, valueFormatter: sparklineValueFormatter
            )
            .frame(height: sparklineHeight)
            .padding(.top, 2)

            // Detail breakdown rows
            if showDetails {
                Divider()
                    .opacity(0.3)
                    .padding(.top, 2)

                VStack(spacing: 2) {
                    ForEach(details, id: \.label) { detail in
                        detailRow(detail)
                    }
                }
            }
        }
        .padding(.horizontal, emphasized ? 14 : (compact ? 10 : 12))
        .padding(.vertical, emphasized ? 12 : (compact ? 8 : 10))
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            emphasized ? accentColor.opacity(borderOpacity) : tint.opacity(borderOpacity),
                            lineWidth: borderWidth
                        )
                )
                .shadow(color: emphasized ? accentColor.opacity(0.12) : .clear, radius: 8, y: 2)
        }
    }

    @ViewBuilder
    private func detailRow(_ detail: (label: String, value: String, color: Color?)) -> some View {
        let labelColor: Color = detail.color ?? Color.secondary.opacity(0.5)
        let valueColor: Color = detail.color ?? Color.secondary
        HStack {
            Text(detail.label)
                .foregroundColor(labelColor)
            Spacer()
            Text(detail.value)
                .foregroundColor(valueColor)
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

// MARK: - Value gauge

/// 3/4-arc ring gauge with the metric value text centered inside. Used as the
/// hero readout for percentage-based metric cards.
struct ValueGaugeView: View {
    let fraction: Double  // 0.0 – 1.0
    let text: String
    let textFontSize: CGFloat
    let trackColor: Color  // severity-driven fill color
    var diameter: CGFloat = 60

    private let sweep: Double = 0.75  // 270° arc, gap at the bottom
    private var lineWidth: CGFloat { max(diameter * 0.09, 3) }
    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))

            Circle()
                .trim(from: 0, to: sweep * clamped)
                .stroke(trackColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.4), value: clamped)

            Text(text)
                .font(.system(size: textFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, lineWidth + 2)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Severity

enum MetricSeverity {
    case normal
    case warning
    case critical

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    /// Create severity from a 0-100 percentage value.
    static func from(percent: Double, warningAt: Double = 70, criticalAt: Double = 90) -> MetricSeverity {
        if percent >= criticalAt { return .critical }
        if percent >= warningAt { return .warning }
        return .normal
    }
}
