import SwiftUI
import UIKit

/// Identidad visual: ciruela oscura, lavanda de Orchard y un durazno cálido para los acentos.
enum Theme {
    static let accent = Color(red: 0.71, green: 0.63, blue: 1.0)
    static let peach = Color(red: 1.0, green: 0.72, blue: 0.56)
    static let base = Color(red: 0.07, green: 0.055, blue: 0.09)
    static let surface = Color(red: 0.125, green: 0.10, blue: 0.16)
    static let plum = Color(red: 0.30, green: 0.22, blue: 0.45)
    static let hairline = Color.white.opacity(0.08)

    /// Títulos: SF Rounded, grueso. Suave como el nombre de la app.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// El color de la carátula que suena. Tiñe el reproductor y la barra inferior.
@MainActor
final class ArtworkTint: ObservableObject {
    static let shared = ArtworkTint()

    @Published private(set) var color: Color = Theme.plum
    private var cache: [String: Color] = [:]
    private var currentId: String?

    func update(for track: Track?) {
        guard let track else {
            currentId = nil
            withAnimation(.easeInOut(duration: 0.8)) { color = Theme.plum }
            return
        }
        currentId = track.id
        if let known = cache[track.id] {
            withAnimation(.easeInOut(duration: 0.8)) { color = known }
            return
        }
        guard let url = track.thumbnail ?? track.fallbackThumbnail else { return }
        Task {
            guard let response = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: response.0),
                  let found = Self.dominant(in: image) else { return }
            cache[track.id] = found
            if cache.count > 60, let stale = cache.keys.first(where: { $0 != track.id }) { cache[stale] = nil }
            if currentId == track.id {
                withAnimation(.easeInOut(duration: 0.8)) { color = found }
            }
        }
    }

    /// Promedio de la imagen, llevado a un tono que funcione como fondo oscuro.
    static func dominant(in image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let average = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return nil }
        // Las carátulas grises se quedan grises; a las de color se les sube un poco la saturación.
        let tunedSaturation = saturation < 0.1 ? saturation : min(0.85, max(saturation, 0.4) * 1.15)
        return Color(hue: Double(hue), saturation: Double(tunedSaturation), brightness: Double(min(max(brightness, 0.38), 0.62)))
    }
}

/// Botón que se hunde un poco al tocarlo.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Tres barras que bailan sobre la carátula de la canción que suena.
struct EqualizerBars: View {
    var animating: Bool
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    private let heights: [(low: CGFloat, high: CGFloat, duration: Double)] = [
        (0.35, 1.0, 0.42), (0.9, 0.3, 0.55), (0.5, 0.85, 0.36),
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                let bar = heights[index]
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 16 * (animating && !reduceMotion ? (up ? bar.high : bar.low) : 0.45))
                    .animation(animating && !reduceMotion
                               ? .easeInOut(duration: bar.duration).repeatForever(autoreverses: true)
                               : .easeOut(duration: 0.2), value: up)
            }
        }
        .frame(height: 16, alignment: .bottom)
        .onAppear { up = true }
        .accessibilityHidden(true)
    }
}

/// Bloque gris que late mientras llega el contenido.
struct Skeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var corner: CGFloat = 10
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.white.opacity(dim ? 0.05 : 0.11))
            .frame(width: width, height: height)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// Barra de progreso propia: fina en reposo, más gruesa mientras la arrastras.
struct Scrubber: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @Binding var scrubbing: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let value = scrubbing ?? position
            let progress = duration > 0 ? min(max(value / duration, 0), 1) : 0
            let active = scrubbing != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white).frame(width: width * progress)
            }
            .frame(height: active ? 10 : 5)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard duration > 0 else { return }
                        scrubbing = min(max(drag.location.x / width, 0), 1) * duration
                    }
                    .onEnded { _ in
                        if let target = scrubbing { onSeek(target) }
                        scrubbing = nil
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Posición")
        .accessibilityValue("\(formatTime(scrubbing ?? position)) de \(formatTime(duration))")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 10.0 : -10.0
            onSeek(min(max(position + step, 0), max(duration - 1, 0)))
        }
    }
}
