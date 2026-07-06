import SwiftUI
import UsageKunCore

struct ProviderLogo: View {
    let provider: UsageProvider
    let color: Color
    let size: CGFloat

    var body: some View {
        switch provider {
        case .claude:
            AnthropicMark(color: color)
                .frame(width: size, height: size)
        case .codex:
            OpenAIMark(color: color)
                .frame(width: size, height: size)
        }
    }
}

private struct AnthropicMark: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let length = size.height * 0.72
            let width = size.width * 0.16

            for index in 0..<4 {
                let angle = Double(index) * .pi / 4
                var transform = CGAffineTransform(translationX: center.x, y: center.y)
                transform = transform.rotated(by: angle)
                let rect = CGRect(x: -width / 2, y: -length / 2, width: width, height: length)
                let path = Path(roundedRect: rect, cornerRadius: width / 2)
                    .applying(transform)
                context.fill(path, with: .color(color))
            }
        }
    }
}

private struct OpenAIMark: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            drawHexagon(context: context, size: size, color: color)
        }
    }

    private func drawHexagon(context: GraphicsContext, size: CGSize, color: Color) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outerRadius = min(size.width, size.height) * 0.46
        let innerRadius = outerRadius * 0.42
        let strokeWidth = outerRadius * 0.22

        let hexPath = hexagonPath(center: center, radius: outerRadius)
        context.stroke(
            hexPath,
            with: .color(color),
            style: StrokeStyle(lineWidth: strokeWidth, lineJoin: .round)
        )

        for index in 0..<3 {
            let spoke = spokePath(center: center, index: index, length: innerRadius)
            context.stroke(
                spoke,
                with: .color(color),
                style: StrokeStyle(lineWidth: strokeWidth * 0.75, lineCap: .round)
            )
        }
    }

    private func hexagonPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for index in 0..<6 {
            let angle = (Double(index) * .pi / 3) - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private func spokePath(center: CGPoint, index: Int, length: CGFloat) -> Path {
        let angle = (Double(index) * 2 * .pi / 3) - .pi / 2
        var path = Path()
        path.move(to: center)
        path.addLine(
            to: CGPoint(
                x: center.x + cos(angle) * length,
                y: center.y + sin(angle) * length
            )
        )
        return path
    }
}
