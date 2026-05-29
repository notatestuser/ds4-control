import SwiftUI

struct SparklineView: View {
    let dataPoints: [(Date, Double)]
    let lineColor: Color
    let maxPoints: Int
    let fixedRange: (min: Double, max: Double)?
    let timeRangeSeconds: TimeInterval?
    var valueFormatter: ((Double) -> String)?

    @State private var hoverIndex: Int?

    init(
        dataPoints: [(Date, Double)],
        lineColor: Color = .blue,
        maxPoints: Int = 1800,
        fixedRange: (min: Double, max: Double)? = nil,
        timeRangeSeconds: TimeInterval? = nil,
        valueFormatter: ((Double) -> String)? = nil
    ) {
        self.dataPoints = dataPoints
        self.lineColor = lineColor
        self.maxPoints = maxPoints
        self.fixedRange = fixedRange
        self.timeRangeSeconds = timeRangeSeconds
        self.valueFormatter = valueFormatter
    }

    private var visibleData: [(Date, Double)] {
        Array(dataPoints.suffix(maxPoints))
    }

    private var visibleValues: [Double] {
        visibleData.map(\.1)
    }

    var body: some View {
        GeometryReader { geometry in
            let data = visibleData
            let values = data.map(\.1)
            if values.count >= 2 {
                let minVal = fixedRange?.min ?? values.min() ?? 0
                let maxVal = fixedRange?.max ?? values.max() ?? 1
                let range = max(maxVal - minVal, 0.001)

                // Position points proportionally within the time window, anchored
                // to the right edge. Newest sample sits at the right; older samples
                // scroll left. Before enough history accumulates, the left side
                // stays empty (Activity Monitor / Task Manager behavior).
                let now = Date()
                let dataSpan = now.timeIntervalSince(data.first!.0)
                let effectiveDuration = timeRangeSeconds ?? max(dataSpan, 1)
                let effectiveStart = now.addingTimeInterval(-effectiveDuration)
                let xPositions: [CGFloat] = data.map { point in
                    let elapsed = point.0.timeIntervalSince(effectiveStart)
                    return geometry.size.width * CGFloat(elapsed / effectiveDuration)
                }

                ZStack(alignment: .topLeading) {
                    // Horizontal grid lines (4 lines at 25%, 50%, 75%, 100%)
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                        let y = geometry.size.height - CGFloat(fraction) * geometry.size.height
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    }

                    // Fill gradient beneath the line
                    SparklineFillShape(values: values, xPositions: xPositions, minVal: minVal, range: range)
                        .fill(
                            LinearGradient(
                                colors: [lineColor.opacity(0.25), lineColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Line stroke
                    SparklineShape(values: values, xPositions: xPositions, minVal: minVal, range: range)
                        .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    // Hover indicator
                    if let idx = hoverIndex, idx < values.count {
                        let x = xPositions[idx]
                        let normalised = CGFloat((values[idx] - minVal) / range)
                        let y = geometry.size.height - normalised * geometry.size.height

                        // Vertical guide line
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(lineColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

                        // Dot on the line
                        Circle()
                            .fill(lineColor)
                            .frame(width: 6, height: 6)
                            .position(x: x, y: y)

                        // Tooltip
                        sparklineTooltip(index: idx, x: x, containerWidth: geometry.size.width)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        // Find the closest data point to the hover x position
                        let hoverX = location.x
                        var closestIdx = 0
                        var closestDist = CGFloat.greatestFiniteMagnitude
                        for (i, px) in xPositions.enumerated() {
                            let dist = abs(px - hoverX)
                            if dist < closestDist {
                                closestDist = dist
                                closestIdx = i
                            }
                        }
                        hoverIndex = closestIdx
                    case .ended:
                        hoverIndex = nil
                    @unknown default:
                        hoverIndex = nil
                    }
                }
            } else {
                // Not enough data — show a flat baseline
                Path { path in
                    let y = geometry.size.height * 0.5
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
                .stroke(lineColor.opacity(0.3), lineWidth: 1)
            }
        }
    }

    private func sparklineTooltip(index: Int, x: CGFloat, containerWidth: CGFloat) -> some View {
        let data = visibleData
        let point = data[index]
        let formattedValue = valueFormatter?(point.1) ?? defaultFormat(point.1)
        let formattedTime = timeFormatter.string(from: point.0)

        // Anchor tooltip to the left or right of the cursor to stay in bounds
        let anchorRight = x < containerWidth / 2

        return VStack(alignment: .leading, spacing: 2) {
            Text(formattedValue)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(formattedTime)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .fixedSize()
        .position(x: anchorRight ? x + 45 : x - 45, y: 0)
    }

    private func defaultFormat(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1f MB/s", value / (1024 * 1024))
        }
        if value >= 1_000 {
            return String(format: "%.0f KB/s", value / 1024)
        }
        if fixedRange != nil {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.1f", value)
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }
}

// MARK: - Shapes

private struct SparklineShape: Shape {
    let values: [Double]
    let xPositions: [CGFloat]
    let minVal: Double
    let range: Double

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }

        return Path { path in
            for (index, value) in values.enumerated() {
                let x = xPositions[index]
                let normalised = CGFloat((value - minVal) / range)
                let y = rect.height - normalised * rect.height
                let point = CGPoint(x: x, y: y)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }
}

private struct SparklineFillShape: Shape {
    let values: [Double]
    let xPositions: [CGFloat]
    let minVal: Double
    let range: Double

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }

        return Path { path in
            // Start at bottom beneath first data point
            path.move(to: CGPoint(x: xPositions[0], y: rect.height))

            for (index, value) in values.enumerated() {
                let x = xPositions[index]
                let normalised = CGFloat((value - minVal) / range)
                let y = rect.height - normalised * rect.height
                path.addLine(to: CGPoint(x: x, y: y))
            }

            // Close along the bottom
            path.addLine(to: CGPoint(x: xPositions[values.count - 1], y: rect.height))
            path.closeSubpath()
        }
    }
}
