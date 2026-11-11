import SwiftUI

struct EqualizerView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    var showsClose = false

    private var activePreset: Equalizer.Preset? {
        Equalizer.presets.first { preset in
            zip(preset.gains, settings.eqBands).allSatisfy { abs($0 - $1) < 0.01 }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Toggle(isOn: $settings.eqEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ecualizador").font(Theme.display(28))
                        Text(settings.eqEnabled ? "Activado" : "Desactivado")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.accent)

                Picker("Modo", selection: $settings.eqFull) {
                    Text("Simple").tag(false)
                    Text("Completo").tag(true)
                }
                .pickerStyle(.segmented)

                ResponseCurve(gains: settings.eqEffective)
                    .frame(height: 96)
                    .opacity(settings.eqEnabled ? 1 : 0.35)

                Group {
                    if settings.eqFull { full } else { simple }
                }
                .disabled(!settings.eqEnabled)
                .opacity(settings.eqEnabled ? 1 : 0.45)

                Button("Restablecer") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if settings.eqFull {
                            settings.eqBands = [Double](repeating: 0, count: 10)
                        } else {
                            settings.eqSimple = [0, 0, 0]
                        }
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(!settings.eqEnabled)

                Text("Al subir una banda, el volumen general baja un poco para que el sonido no se distorsione.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .animation(.easeOut(duration: 0.2), value: settings.eqFull)
            .animation(.easeOut(duration: 0.2), value: settings.eqEnabled)
        }
        .background(Theme.base.ignoresSafeArea())
        .navigationTitle("Ecualizador")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsClose {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
        }
        .onChange(of: settings.eqEnabled) { enabled in
            // El ecualizador se conecta al cargar la canción: recargarla para oír el cambio ahora.
            if enabled { player.reloadKeepingPosition() }
        }
    }

    // MARK: Simple

    private var simple: some View {
        VStack(spacing: 18) {
            simpleRow("Graves", icon: "speaker.wave.3.fill", index: 0)
            simpleRow("Medios", icon: "music.mic", index: 1)
            simpleRow("Agudos", icon: "bell.fill", index: 2)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func simpleRow(_ title: String, icon: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon).font(.body.weight(.semibold))
                Spacer()
                Text(decibels(settings.eqSimple[index]))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(settings.eqSimple[index] == 0 ? Color.secondary : Theme.accent)
            }
            Slider(value: Binding(
                get: { settings.eqSimple[index] },
                set: { settings.eqSimple[index] = ($0).rounded() }
            ), in: Equalizer.range, step: 1)
            .tint(Theme.accent)
            .accessibilityLabel(title)
            .accessibilityValue(decibels(settings.eqSimple[index]))
        }
    }

    // MARK: Completo

    private var full: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Equalizer.presets) { preset in
                        Button {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                settings.eqBands = preset.gains
                            }
                        } label: {
                            Text(preset.name)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(activePreset == preset ? Theme.accent : Theme.surface, in: Capsule())
                                .foregroundStyle(activePreset == preset ? Color.black : Color.primary)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<10, id: \.self) { index in
                    VStack(spacing: 8) {
                        Text(short(settings.eqBands[index]))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(settings.eqBands[index] == 0 ? Color.secondary : Theme.accent)
                        VerticalSlider(value: Binding(
                            get: { settings.eqBands[index] },
                            set: { settings.eqBands[index] = $0 }
                        ), range: Equalizer.range)
                        .frame(height: 190)
                        .accessibilityLabel("\(Equalizer.labels[index]) hercios")
                        .accessibilityValue(decibels(settings.eqBands[index]))
                        Text(Equalizer.labels[index])
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func decibels(_ value: Double) -> String {
        value == 0 ? "0 dB" : String(format: "%+.0f dB", value)
    }

    private func short(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%+.0f", value)
    }
}

/// Deslizador vertical: la barra crece desde el centro hacia arriba o abajo.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let span = range.upperBound - range.lowerBound
            let fraction = (value - range.lowerBound) / span
            let thumbY = height * (1 - fraction)
            let centerY = height / 2
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 5)
                    .frame(maxHeight: .infinity)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 5, height: max(abs(thumbY - centerY), 0.5))
                    .offset(y: min(thumbY, centerY))
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 12, height: 1)
                    .offset(y: centerY)
                Circle()
                    .fill(Color.white)
                    .frame(width: dragging ? 24 : 18, height: dragging ? 24 : 18)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .offset(y: thumbY - (dragging ? 12 : 9))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let clamped = min(max(drag.location.y / height, 0), 1)
                        let raw = range.upperBound - clamped * span
                        // Se pega al cero y avanza de a 1 dB.
                        value = abs(raw) < 0.6 ? 0 : raw.rounded()
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
        }
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            value = min(max(value + step, range.lowerBound), range.upperBound)
        }
    }
}

/// Dibujo de cómo queda el sonido: la curva sube donde se refuerza y baja donde se atenúa.
struct ResponseCurve: View {
    let gains: [Double]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = curvePoints(in: size)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                smooth(points, closingTo: size.height)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                smooth(points, closingTo: nil)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: gains)
        .accessibilityHidden(true)
    }

    private func curvePoints(in size: CGSize) -> [CGPoint] {
        guard gains.count > 1 else { return [] }
        let span = Equalizer.range.upperBound - Equalizer.range.lowerBound
        return gains.enumerated().map { index, gain in
            let x = size.width * CGFloat(index) / CGFloat(gains.count - 1)
            let y = size.height * CGFloat(1 - (gain - Equalizer.range.lowerBound) / span)
            return CGPoint(x: x, y: min(max(y, 2), size.height - 2))
        }
    }

    private func smooth(_ points: [CGPoint], closingTo bottom: CGFloat?) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let middle = (previous.x + current.x) / 2
            path.addCurve(to: current, control1: CGPoint(x: middle, y: previous.y), control2: CGPoint(x: middle, y: current.y))
        }
        if let bottom {
            path.addLine(to: CGPoint(x: last.x, y: bottom))
            path.addLine(to: CGPoint(x: first.x, y: bottom))
            path.closeSubpath()
        }
        return path
    }
}
