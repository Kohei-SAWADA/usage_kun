import SwiftUI
import UsageKunCore

struct UsageCardView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        let accent = snapshot.provider.accent

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    ProviderMark(provider: snapshot.provider, accent: accent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.provider.displayName)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.textPrimary)

                        HStack(spacing: 6) {
                            Text(snapshot.status.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(accent)

                            Text(snapshot.source)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AppTheme.textFaint)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Text(snapshot.percentDisplay)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .monospacedDigit()
            }

            UsageBar(percent: snapshot.percent ?? 0, accent: accent)

            HStack(spacing: 8) {
                DataChip(title: snapshot.metricTitle, value: snapshot.usedDisplay, accent: accent)
                DataChip(title: snapshot.secondaryTitle, value: snapshot.secondaryValue ?? resetDisplay, accent: accent)
            }

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
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(accent.opacity(0.38), lineWidth: 1)
                )
        )
    }

    private var resetDisplay: String {
        guard let resetAt = snapshot.resetAt else { return "--" }
        let seconds = max(Int(resetAt.timeIntervalSinceNow), 0)
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}

private struct ProviderMark: View {
    let provider: UsageProvider
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.16))

            ProviderLogo(provider: provider, color: accent, size: 26)
        }
        .frame(width: 40, height: 40)
    }
}

private struct UsageBar: View {
    let percent: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = width * min(max(percent, 0), 100) / 100

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AppTheme.barTrack)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent)
                    .frame(width: max(5, fill))
                    .shadow(color: accent.opacity(0.35), radius: 8, y: 0)
            }
        }
        .frame(height: 7)
    }
}

private struct DataChip: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textFaint)

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(AppTheme.panelHover)
        .overlay(accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
