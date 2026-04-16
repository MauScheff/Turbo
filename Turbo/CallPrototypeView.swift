import SwiftUI
import UIKit

private struct HatTextureTuning: Equatable {
    var zoom: CGFloat = 1.85
    var opacity: Double = 0.9
    var lineWidth: CGFloat = 1.0
}

struct TurboCallPrototypeView: View {
    let contactName: String
    let contactHandle: String
    let onClose: () -> Void

    @State private var tuning = HatTextureTuning()
    @State private var showsTextureControls = true

    var body: some View {
        ZStack {
            HatTilingBackground(tuning: tuning)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, 18)

                identityRow

                Spacer(minLength: 0)

                bottomStack
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(TurboCallControlButtonStyle())
            .accessibilityLabel("Close call prototype")
        }
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 18) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 82, height: 82)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    Text(initials(for: contactName))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(contactName)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2)

                Text(contactHandle)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var bottomStack: some View {
        VStack(spacing: 18) {
            if showsTextureControls {
                textureControls
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button("Show Tuning") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsTextureControls = true
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .buttonStyle(.plain)
            }

            actionButtons
        }
    }

    private var textureControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Texture Tuning")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .textCase(.uppercase)
                    .tracking(1.4)

                Spacer()

                Button("Hide") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsTextureControls = false
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .buttonStyle(.plain)

                Button("Reset") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        tuning = HatTextureTuning()
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
                .buttonStyle(.plain)
            }

            TurboTuningSliderRow(
                title: "Zoom",
                valueText: String(format: "%.2f", tuning.zoom),
                value: $tuning.zoom,
                range: 1.0...2.4
            )
            TurboTuningSliderRow(
                title: "Darken",
                valueText: String(format: "%.2f", tuning.opacity),
                value: $tuning.opacity,
                range: 0.7...0.98
            )
            TurboTuningSliderRow(
                title: "Line",
                valueText: String(format: "%.2f", tuning.lineWidth),
                value: $tuning.lineWidth,
                range: 0.55...1.8
            )
        }
        .padding(16)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        HStack(alignment: .top, spacing: 28) {
            TurboCallActionButton(
                title: "Leave",
                symbolName: "xmark",
                tint: Color(red: 0.96, green: 0.28, blue: 0.24),
                highlight: Color(red: 0.55, green: 0.13, blue: 0.11)
            )

            TurboCallActionButton(
                title: "Talk",
                symbolName: "waveform",
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
                    .overlay(
                        Image(systemName: symbolName)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                    )

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

private struct TurboTuningSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    let valueText: String
    @Binding var value: Value
    let range: ClosedRange<Value>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Slider(value: $value, in: range)
                .tint(.white.opacity(0.78))
        }
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
    private struct RenderRequest: Equatable {
        let size: CGSize
        let tuning: HatTextureTuning
    }

    let tuning: HatTextureTuning
    @State private var renderedTexture: CGImage?

    private struct PolygonRecord {
        let points: [CGPoint]
        let bounds: CGRect
    }

    private static let fieldPolygons = HatTilingGenerator.patchPolygons(level: 5)
    private static let fieldRecords = fieldPolygons.map { polygon in
        PolygonRecord(
            points: polygon,
            bounds: HatTilingGenerator.boundingBox(for: [polygon])
        )
    }
    private static let fieldBounds = HatTilingGenerator.boundingBox(for: fieldPolygons)
    private static let fieldCenter = CGPoint(
        x: fieldBounds.midX,
        y: fieldBounds.midY
    )
    private static let referenceBounds = HatTilingGenerator.boundingBox(
        for: HatTilingGenerator.polygons(level: 1, tileIndex: 0)
    )

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let request = RenderRequest(size: size, tuning: tuning)

            ZStack {
                Color.white
                    .ignoresSafeArea()

                if let renderedTexture {
                    Image(decorative: renderedTexture, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                }

                Color.black
                    .opacity(tuning.opacity)
                    .ignoresSafeArea()
            }
            .task(id: request) {
                guard size.width > 0, size.height > 0 else { return }
                renderedTexture = renderTexture(size: size, tuning: tuning)
            }
        }
    }

    private func renderTexture(size: CGSize, tuning: HatTextureTuning) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            cgContext.setAllowsAntialiasing(true)
            cgContext.setShouldAntialias(true)
            drawField(context: cgContext, size: size, tuning: tuning)
        }
        return image.cgImage
    }

    private func drawField(
        context: CGContext,
        size: CGSize,
        tuning: HatTextureTuning
    ) {
        let targetWidth = min(size.width, size.height) * 0.42 * tuning.zoom
        let scale = targetWidth / max(Self.referenceBounds.width, 1)
        let viewport = CGRect(
            x: -80,
            y: -80,
            width: size.width + 160,
            height: size.height + 160
        )

        drawTexture(
            context: context,
            polygons: Self.fieldRecords,
            sourceCenter: Self.fieldCenter,
            destinationCenter: CGPoint(
                x: size.width * 0.5,
                y: size.height * 0.54
            ),
            scale: scale,
            viewport: viewport,
            opacity: tuning.opacity
        )
    }

    private func drawTexture(
        context: CGContext,
        polygons: [PolygonRecord],
        sourceCenter: CGPoint,
        destinationCenter: CGPoint,
        scale: CGFloat,
        viewport: CGRect,
        opacity: Double
    ) {
        for polygon in polygons {
            let transformedBounds = CGRect(
                x: destinationCenter.x + (polygon.bounds.minX - sourceCenter.x) * scale,
                y: destinationCenter.y + (polygon.bounds.minY - sourceCenter.y) * scale,
                width: polygon.bounds.width * scale,
                height: polygon.bounds.height * scale
            )

            guard transformedBounds.intersects(viewport) else { continue }

            let path = CGMutablePath()

            for (index, point) in polygon.points.enumerated() {
                let transformed = transform(
                    point: point,
                    sourceCenter: sourceCenter,
                    destinationCenter: destinationCenter,
                    scale: scale
                )

                if index == 0 {
                    path.move(to: transformed)
                } else {
                    path.addLine(to: transformed)
                }
            }

            path.closeSubpath()
            context.addPath(path)
            context.setStrokeColor(UIColor.black.cgColor)
            context.setLineWidth(max(0.65, scale * 0.138 * tuning.lineWidth))
            context.strokePath()
        }
    }

    private func transform(
        point: CGPoint,
        sourceCenter: CGPoint,
        destinationCenter: CGPoint,
        scale: CGFloat
    ) -> CGPoint {
        let translatedX = (point.x - sourceCenter.x) * scale
        let translatedY = (point.y - sourceCenter.y) * scale

        return CGPoint(
            x: destinationCenter.x + translatedX,
            y: destinationCenter.y + translatedY
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
