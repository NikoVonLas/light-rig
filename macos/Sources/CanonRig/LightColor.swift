import SwiftUI

enum LightColorMode { case rgb, temperature }

struct LightRGB: Equatable {
    let red: Int
    let green: Int
    let blue: Int

    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    static let kelvinRange = 2200...9000

    // Approximate sRGB white points for the WS2812B, with neutral white at 6500 K.
    static func white(kelvin: Int) -> Self {
        let stops: [(Int, Self)] = [
            (2200, .init(red: 255, green: 146, blue: 39)),
            (3200, .init(red: 255, green: 184, blue: 123)),
            (4500, .init(red: 255, green: 218, blue: 187)),
            (5500, .init(red: 255, green: 237, blue: 222)),
            (6500, .init(red: 255, green: 255, blue: 255)),
            (9000, .init(red: 210, green: 224, blue: 255))
        ]
        var (start, left) = stops[0]
        for (end, right) in stops.dropFirst() {
            if kelvin <= end {
                let t = Double(max(kelvin, start) - start) / Double(end - start)
                func mix(_ a: Int, _ b: Int) -> Int { a + Int((Double(b - a) * t).rounded()) }
                return Self(red: mix(left.red, right.red), green: mix(left.green, right.green), blue: mix(left.blue, right.blue))
            }
            (start, left) = (end, right)
        }
        return left
    }
}

struct WheelSelection: Equatable {
    var hue: Double
    var saturation: Double

    var value = 1.0

    init(hue: Double, saturation: Double) {
        self.hue = hue
        self.saturation = saturation
    }

    init(color: LightRGB) {
        let r = Double(color.red), g = Double(color.green), b = Double(color.blue)
        let high = max(r, g, b), delta = high - min(r, g, b)
        value = high / 255
        saturation = high == 0 ? 0 : delta / high
        if delta == 0 { hue = 0 }
        else if high == r { hue = (g - b) / delta / 6 }
        else if high == g { hue = ((b - r) / delta + 2) / 6 }
        else { hue = ((r - g) / delta + 4) / 6 }
        if hue < 0 { hue += 1 }
    }

    var rgb: LightRGB {
        let h = hue * 6
        func channel(_ offset: Double) -> Int {
            let k = (offset + h).truncatingRemainder(dividingBy: 6)
            let chroma = max(0, min(1, min(k, 4 - k)))
            return Int((255 * value * (1 - saturation * chroma)).rounded())
        }
        return LightRGB(red: channel(5), green: channel(3), blue: channel(1))
    }
}

struct LightColorWheel: View {
    @Binding var selection: WheelSelection
    private let diameter = 116.0

    var body: some View {
        let radius = diameter / 2
        let angle = selection.hue * 2 * .pi
        ZStack {
            Circle().fill(AngularGradient(colors: (0...6).map {
                WheelSelection(hue: Double($0) / 6, saturation: 1).rgb.color
            }, center: .center))
            Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: radius))
            Circle().fill(selection.rgb.color)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.8), radius: 2)
                .frame(width: 13, height: 13)
                .offset(x: cos(angle) * radius * selection.saturation,
                        y: sin(angle) * radius * selection.saturation)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let x = drag.location.x - radius, y = drag.location.y - radius
            let hue = atan2(y, x) / (2 * .pi)
            selection = WheelSelection(hue: hue < 0 ? hue + 1 : hue, saturation: min(1, hypot(x, y) / radius))
        })
        .accessibilityRepresentation {
            VStack {
                Slider(value: $selection.hue, in: 0...1, step: 1.0 / 360) { Text("Оттенок") }
                Slider(value: $selection.saturation, in: 0...1, step: 0.01) { Text("Насыщенность") }
            }
        }
    }
}
