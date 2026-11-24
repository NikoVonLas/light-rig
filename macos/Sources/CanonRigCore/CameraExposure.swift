import Foundation

public struct CameraProperty: Equatable, Sendable {
    public var raw: UInt32?
    public var options: [UInt32] = []
    public var optionsKnown = false

    public init() {}

    init(json: JSONValue?) {
        guard case .object(let object) = json else { return }
        raw = Self.code(object["raw"])
        if case .bool(let known) = object["optionsKnown"] { optionsKnown = known }
        if optionsKnown, case .array(let values) = object["options"] {
            options = values.compactMap { Self.code($0) }
        }
    }

    private static func code(_ value: JSONValue?) -> UInt32? {
        guard case .number(let number) = value, number.isFinite,
              number >= 0, number <= Double(UInt32.max), number.rounded() == number else { return nil }
        return UInt32(number)
    }
}

public enum CameraExposureKind: Sendable {
    case aperture, shutter, iso, focusMode, afMethod, movieServo

    public var propertyKey: String {
        switch self {
        case .aperture: "aperture"
        case .shutter: "shutter"
        case .iso: "iso"
        case .focusMode: "focusMode"
        case .afMethod: "afMethod"
        case .movieServo: "movieServo"
        }
    }

    public func label(_ raw: UInt32?) -> String {
        guard let raw else { return "—" }
        if raw == 0 && (self == .aperture || self == .shutter || self == .iso) { return "Auto" }
        let known: String?
        switch self {
        case .focusMode:
            known = [UInt32(0): "One Shot", 1: "Servo AF", 2: "AI Focus", 3: "MF — ручной"][raw]
        case .afMethod:
            known = [UInt32(0): "Quick AF", 1: "Одна точка", 2: "Лицо", 3: "Многозонный AF", 4: "Зона",
                     5: "Расширение: крест", 6: "Расширение: окружение", 7: "Большая зона: горизонталь",
                     8: "Большая зона: вертикаль", 9: "Лицо + слежение", 10: "Точечный AF",
                     11: "Гибкая зона 1", 12: "Гибкая зона 2", 13: "Гибкая зона 3", 14: "Вся область"][raw]
        case .movieServo:
            known = [UInt32(0): "Выкл.", 1: "Вкл."][raw]
        case .aperture:
            if raw == 0xffff || raw == 0xb0 { return "Auto" }
            let values = "1 1.1 1.2 1.4 1.6 1.8 2 2.2 2.5 2.8 3.2 3.5 4 4.5 5 5.6 6.3 7.1 8 9 10 11 13 14 16 18 20 22 25 29 32 36 40 45 51 57 64 72 81 91"
            let halves: [UInt32: String] = [0x0c:"1.2", 0x14:"1.8", 0x1c:"2.5", 0x24:"3.5", 0x2c:"4.5", 0x34:"6.7", 0x3c:"9.5", 0x44:"13", 0x4c:"19", 0x54:"27", 0x5c:"38", 0x64:"54", 0x6c:"76"]
            known = (thirdStop(raw, base: 0x08, values: values) ?? halves[raw]).map { "f/" + $0 }
        case .iso:
            if raw == 1 { return "Auto" }
            let values = "100 125 160 200 250 320 400 500 640 800 1000 1250 1600 2000 2500 3200 4000 5000 6400 8000 10000 12800 16000 20000 25600 32000 40000 51200 64000 80000 102400"
            known = thirdStop(raw, base: 0x48, values: values) ??
                [UInt32(0x28):"6", 0x30:"12", 0x38:"25", 0x40:"50", 0x43:"64", 0x45:"80", 0xa0:"204800", 0xa8:"409600", 0xb0:"819200"][raw]
        case .shutter:
            if raw == 4 || raw == 12 { return "Bulb" }
            let denominators = "4 5 6 8 10 13 15 20 25 30 40 50 60 80 100 125 160 200 250 320 400 500 640 800 1000 1250 1600 2000 2500 3200 4000 5000 6400 8000"
            let halves: [UInt32:String] = [0x4c:"6", 0x54:"10", 0x5c:"20", 0x64:"45", 0x6c:"90", 0x74:"180", 0x7c:"350", 0x84:"750", 0x8c:"1500", 0x94:"3000", 0x9c:"6000", 0xa8:"16000"]
            if let denominator = thirdStop(raw, base: 0x48, values: denominators) ?? halves[raw] {
                known = "1/" + denominator + " с"
            } else {
                let seconds = "30 25 20 15 13 10.3 8 6.3 5 4 3.2 2.5 2 1.6 1.3 1 0.8 0.6 0.5 0.4 0.3"
                let halves: [UInt32:String] = [0x14:"20.3", 0x1c:"10", 0x24:"6", 0x2c:"3", 0x34:"1.5", 0x3c:"0.7", 0x44:"0.3"]
                known = (thirdStop(raw, base: 0x10, values: seconds) ?? halves[raw]).map { $0 + " с" }
            }
        }
        return known ?? String(format: "Код 0x%04X", raw)
    }

    // Canon's third-stop codes use offsets 0, 3, 5 in each group of eight.
    private func thirdStop(_ raw: UInt32, base: UInt32, values: String) -> String? {
        guard raw >= base else { return nil }
        let delta = raw - base
        let fraction: UInt32
        switch delta % 8 {
        case 0: fraction = 0
        case 3: fraction = 1
        case 5: fraction = 2
        default: return nil
        }
        let index = Int(delta / 8) * 3 + Int(fraction)
        let labels = values.split(separator: " ")
        return labels.indices.contains(index) ? String(labels[index]) : nil
    }
}
