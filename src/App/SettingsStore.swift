import Foundation

enum Edge: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case right
    case both

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct Settings: Codable, Equatable, Sendable {
    var enabled = true
    var edge: Edge = .right
    var edgeWidth: Float = 0.08
    var sensitivity: Float = 1.0
    var inverted = false
    var requireOption = false
    var showsHUD = true
    var excludedBundleIDs: [String] = []

    static let `default` = Settings()

    private enum CodingKeys: String, CodingKey {
        case enabled, edge, edgeWidth, sensitivity, inverted, requireOption, showsHUD, excludedBundleIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        edge = try values.decodeIfPresent(Edge.self, forKey: .edge) ?? .right
        edgeWidth = try values.decodeIfPresent(Float.self, forKey: .edgeWidth) ?? 0.08
        sensitivity = try values.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 1.0
        inverted = try values.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        requireOption = try values.decodeIfPresent(Bool.self, forKey: .requireOption) ?? false
        showsHUD = try values.decodeIfPresent(Bool.self, forKey: .showsHUD) ?? true
        excludedBundleIDs = try values.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? []
    }

    func validated() -> Settings? {
        guard edgeWidth.isFinite, (0.03...0.20).contains(edgeWidth),
              sensitivity.isFinite, (0.25...2.0).contains(sensitivity),
              excludedBundleIDs.count <= 32,
              excludedBundleIDs.allSatisfy(Self.isValidBundleID)
        else {
            return nil
        }
        return self
    }

    private static func isValidBundleID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "glide.settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Settings {
        guard let data = defaults.data(forKey: key),
              var settings = try? JSONDecoder().decode(Settings.self, from: data),
              settings.validated() != nil
        else {
            return .default
        }

        // Glide intentionally resumes on every launch; pause is session-only.
        settings.enabled = true
        return settings
    }

    func save(_ settings: Settings) {
        guard var valid = settings.validated() else { return }
        valid.enabled = true
        guard let data = try? JSONEncoder().encode(valid) else { return }
        defaults.set(data, forKey: key)
    }
}
