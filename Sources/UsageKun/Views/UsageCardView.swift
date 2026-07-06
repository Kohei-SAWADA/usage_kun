import SwiftUI
import UsageKunCore

struct UsageCardView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let accent = snapshot.provider.accent

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ProviderMark(provider: snapshot.provider, accent: accent)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(snapshot.provider.displayName)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)

                        Text(snapshot.status.label.uppercased())
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(accent.opacity(0.13))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }

                    Text(snapshot.source.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textFaint)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(snapshot.percentDisplay)
                        .font(.system(size: 31, weight: .black, design: .rounded))
                        .foregroundStyle(accent)
                        .monospacedDigit()

                    Text("5-HOUR")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(AppTheme.textFaint)
                }
            }

            WindowMeterStack(snapshot: snapshot, accent: accent)

            if let message = snapshot.message {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.panel)
                .overlay(HackerGrid(accent: accent.opacity(0.10)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(accent.opacity(0.42), lineWidth: 1)
                )
        )
    }
}

private struct ProviderMark: View {
    let provider: UsageProvider
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(accent.opacity(0.45), lineWidth: 1)
                )

            ProviderLogo(provider: provider, color: accent, size: 25)
        }
        .frame(width: 42, height: 42)
    }
}

private struct WindowMeterStack: View {
    let snapshot: UsageSnapshot
    let accent: Color

    var body: some View {
        VStack(spacing: 11) {
            LimitMeterRow(
                title: "5-HOUR LIMIT",
                subtitle: "PRIMARY WINDOW",
                percent: snapshot.percent,
                resetAt: snapshot.resetAt,
                detail: snapshot.percent == nil ? snapshot.usedDisplay : nil,
                accent: accent,
                barHeight: 10,
                isPrimary: true
            )

            if let weekly = snapshot.weekly {
                LimitMeterRow(
                    title: "1-WEEK WINDOW",
                    subtitle: "SECONDARY QUOTA",
                    percent: weekly.percentLeft,
                    resetAt: weekly.resetAt,
                    detail: weekly.detail,
                    accent: accent,
                    barHeight: 5,
                    isPrimary: false
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.background.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.barTrack.opacity(0.85), lineWidth: 1)
                )
        )
    }
}

private struct LimitMeterRow: View {
    let title: String
    let subtitle: String
    let percent: Double?
    let resetAt: Date?
    let detail: String?
    let accent: Color
    let barHeight: CGFloat
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isPrimary ? 8 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: isPrimary ? 11 : 9, weight: .black, design: .monospaced))
                        .foregroundStyle(isPrimary ? AppTheme.textPrimary : AppTheme.textMuted)
                        .tracking(0.6)

                    Text(subtitle)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textFaint)
                        .tracking(0.6)
                }

                Spacer(minLength: 8)

                if let resetAt {
                    Text("RESET \(Self.resetText(resetAt))")
                        .font(.system(size: isPrimary ? 10 : 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textMuted)
                        .monospacedDigit()
                }

                if let percent {
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: isPrimary ? 15 : 11, weight: .black, design: .monospaced))
                        .foregroundStyle(isPrimary ? accent : AppTheme.textMuted)
                        .monospacedDigit()
                        .frame(width: isPrimary ? 45 : 34, alignment: .trailing)
                } else if let detail {
                    Text(detail.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            if let percent {
                UsageBar(
                    percent: percent,
                    accent: accent,
                    height: barHeight,
                    muted: !isPrimary
                )
            } else if detail != nil {
                RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                    .fill(AppTheme.barTrack.opacity(isPrimary ? 1 : 0.55))
                    .frame(height: barHeight)
            }
        }
    }

    private static func resetText(_ resetAt: Date) -> String {
        let seconds = max(Int(resetAt.timeIntervalSinceNow), 0)
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3600
        let minutes = seconds % 3600 / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}

private struct UsageBar: View {
    let percent: Double
    let accent: Color
    let height: CGFloat
    let muted: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = width * min(max(percent, 0), 100) / 100

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(AppTheme.barTrack.opacity(muted ? 0.55 : 1))

                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(accent.opacity(muted ? 0.68 : 1))
                    .frame(width: max(height, fill))
                    .shadow(color: accent.opacity(muted ? 0.16 : 0.40), radius: muted ? 3 : 9, y: 0)
            }
        }
        .frame(height: height)
    }
}

private struct HackerGrid: View {
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let lineColor = GraphicsContext.Shading.color(accent)
            for x in stride(from: 0.0, through: size.width, by: 18.0) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: lineColor, lineWidth: 0.45)
            }

            for y in stride(from: 0.0, through: size.height, by: 18.0) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: lineColor, lineWidth: 0.45)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
