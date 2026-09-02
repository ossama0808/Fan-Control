import Foundation

/// A named snapshot of how every fan should be driven.
public struct Preset: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var isBuiltIn: Bool
    /// Per-fan modes. A fan absent from the map falls back to `fallback`.
    public var modes: [Int: FanMode]
    public var fallback: FanMode

    public init(id: String = UUID().uuidString, name: String,
                isBuiltIn: Bool = false,
                modes: [Int: FanMode] = [:], fallback: FanMode = .auto) {
        self.id = id; self.name = name; self.isBuiltIn = isBuiltIn
        self.modes = modes; self.fallback = fallback
    }

    public func mode(for fan: FanState) -> FanMode {
        if case .constant(let r) = fallback, r == .infinity {
            return .constant(rpm: fan.maxRPM)      // "Full blast" resolves per fan
        }
        return modes[fan.index] ?? fallback
    }

    public static let auto = Preset(id: "builtin.auto", name: "Automatic",
                                    isBuiltIn: true, fallback: .auto)

    /// Uses .infinity as a sentinel meaning "this fan's own maximum", resolved
    /// in `mode(for:)` because each fan can have a different ceiling.
    public static let fullBlast = Preset(id: "builtin.fullblast", name: "Full blast",
                                         isBuiltIn: true,
                                         fallback: .constant(rpm: .infinity))

}
