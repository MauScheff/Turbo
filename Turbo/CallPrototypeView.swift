import SwiftUI

struct TurboCallPrototypeView: View {
    let contactName: String
    let contactHandle: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            HatTilingBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Spacer()

                identityBlock

                Spacer()

                controls
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
    }

    private var topBar: some View {
        HStack {
            Text("Call Prototype")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
                .textCase(.uppercase)
                .tracking(1.8)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(TurboCallControlButtonStyle())
            .accessibilityLabel("Close call prototype")
        }
    }

    private var identityBlock: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 108, height: 108)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    Text(initials(for: contactName))
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                )

            Text(contactName)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
                .multilineTextAlignment(.center)

            Text(contactHandle)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))

            Text("Visual study of the in-call surface")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
        }
        .padding(.horizontal, 20)
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 28) {
            TurboCallActionButton(
                title: "Leave",
                symbolName: "xmark.circle.fill",
                tint: Color(red: 0.96, green: 0.28, blue: 0.24),
                highlight: Color(red: 0.55, green: 0.13, blue: 0.11)
            )

            TurboCallActionButton(
                title: "Talk",
                symbolName: "waveform.circle.fill",
                tint: Color(red: 0.26, green: 0.56, blue: 1.0),
                highlight: Color(red: 0.12, green: 0.28, blue: 0.66)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        let initials = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        if initials.isEmpty, let first = name.first {
            return String(first).uppercased()
        }
        return initials.uppercased()
    }
}

private struct TurboCallActionButton: View {
    let title: String
    let symbolName: String
    let tint: Color
    let highlight: Color

    var body: some View {
        Button(action: {}) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [tint.opacity(0.34), highlight.opacity(0.98)],
                                center: .topLeading,
                                startRadius: 10,
                                endRadius: 76
                            )
                        )
                        .frame(width: 88, height: 88)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )

                    Image(systemName: symbolName)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.white)
                }

                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(TurboCallControlButtonStyle())
        .accessibilityLabel(title)
    }
}

private struct TurboCallControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

private struct HatTilingBackground: View {
    private static let variantPolygons: [[[CGPoint]]] = [
        HatTilingGenerator.polygons(level: 2, tileIndex: 0),
        HatTilingGenerator.polygons(level: 2, tileIndex: 2),
        HatTilingGenerator.polygons(level: 2, tileIndex: 3)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let backgroundRect = CGRect(origin: .zero, size: size)
                context.fill(
                    Path(backgroundRect),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.06, green: 0.07, blue: 0.09),
                            Color(red: 0.03, green: 0.03, blue: 0.04)
                        ]),
                        startPoint: CGPoint(x: size.width * 0.15, y: 0),
                        endPoint: CGPoint(x: size.width * 0.85, y: size.height)
                    )
                )

                let glowPath = Path(
                    ellipseIn: CGRect(
                        x: size.width * 0.12,
                        y: size.height * 0.08,
                        width: size.width * 0.76,
                        height: size.height * 0.54
                    )
                )
                context.fill(
                    glowPath,
                    with: .radialGradient(
                        Gradient(colors: [Color.white.opacity(0.045), .clear]),
                        center: CGPoint(x: size.width * 0.5, y: size.height * 0.34),
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * 0.45
                    )
                )

                let driftX = CGFloat(sin(t * 0.1)) * 16
                let driftY = CGFloat(cos(t * 0.08)) * 12

                let placements: [(variant: Int, centerX: CGFloat, centerY: CGFloat, scale: CGFloat, rotation: CGFloat, opacity: Double)] = [
                    (0, 0.24, 0.22, 0.22, -0.34, 0.12),
                    (1, 0.84, 0.26, 0.2, 0.18, 0.1),
                    (2, 0.52, 0.74, 0.26, -0.08, 0.09)
                ]

                for placement in placements {
                    drawTexture(
                        context: &context,
                        size: size,
                        polygons: Self.variantPolygons[placement.variant],
                        normalizedCenter: CGPoint(
                            x: placement.centerX + driftX / max(size.width, 1),
                            y: placement.centerY + driftY / max(size.height, 1)
                        ),
                        scale: placement.scale,
                        rotation: placement.rotation,
                        opacity: placement.opacity
                    )
                }
            }
        }
    }

    private func drawTexture(
        context: inout GraphicsContext,
        size: CGSize,
        polygons: [[CGPoint]],
        normalizedCenter: CGPoint,
        scale: CGFloat,
        rotation: CGFloat,
        opacity: Double
    ) {
        let bounds = HatTilingGenerator.boundingBox(for: polygons)
        let targetWidth = size.width * scale
        let uniformScale = targetWidth / max(bounds.width, 1)
        let center = CGPoint(x: size.width * normalizedCenter.x, y: size.height * normalizedCenter.y)
        let sourceCenter = CGPoint(x: bounds.midX, y: bounds.midY)

        for polygon in polygons {
            var path = Path()

            for (index, point) in polygon.enumerated() {
                let transformed = transform(
                    point: point,
                    sourceCenter: sourceCenter,
                    destinationCenter: center,
                    scale: uniformScale,
                    rotation: rotation
                )

                if index == 0 {
                    path.move(to: transformed)
                } else {
                    path.addLine(to: transformed)
                }
            }

            path.closeSubpath()

            context.stroke(
                path,
                with: .color(Color.white.opacity(opacity)),
                lineWidth: max(0.7, uniformScale * 0.08)
            )
        }
    }

    private func transform(
        point: CGPoint,
        sourceCenter: CGPoint,
        destinationCenter: CGPoint,
        scale: CGFloat,
        rotation: CGFloat
    ) -> CGPoint {
        let translatedX = (point.x - sourceCenter.x) * scale
        let translatedY = (point.y - sourceCenter.y) * scale
        let cosAngle = CGFloat(cos(rotation))
        let sinAngle = CGFloat(sin(rotation))
        let rotatedX = translatedX * cosAngle - translatedY * sinAngle
        let rotatedY = translatedX * sinAngle + translatedY * cosAngle

        return CGPoint(
            x: destinationCenter.x + rotatedX,
            y: destinationCenter.y + rotatedY
        )
    }
}

#Preview("Call Prototype") {
    TurboCallPrototypeView(
        contactName: "Avery",
        contactHandle: "@avery",
        onClose: {}
    )
}
