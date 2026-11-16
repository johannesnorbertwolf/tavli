import CoreML
import Foundation

/// Where each variant's Core ML value model lives (#143), and whether it is there at
/// all. Every variant names its model via `GameVariant.modelResourceName`
/// (`PlakotoValue`, `PlakotoStandardValue`, `FevgaValue`, `PortesValue`); a model that
/// is not bundled means **no AI for that variant** — the app shows it as "AI not
/// available yet" for vs-AI play instead of silently playing random moves. Dropping
/// the `.mlpackage` into the app's resources is all it takes to enable it.
public struct ModelCatalog: Sendable {
    private let locate: @Sendable (_ name: String, _ ext: String) -> URL?

    /// A catalog over an arbitrary lookup (tests).
    public init(locate: @escaping @Sendable (_ name: String, _ ext: String) -> URL?) {
        self.locate = locate
    }

    /// Models in a bundle's resources (the app: `Bundle.main`).
    public init(bundle: Bundle) {
        let url = bundle.bundleURL
        self.init { name, ext in Bundle(url: url)?.url(forResource: name, withExtension: ext) }
    }

    /// Models in a plain directory (`<dir>/<name>.<ext>`).
    public init(directory: URL) {
        self.init { name, ext in
            let u = directory.appendingPathComponent("\(name).\(ext)")
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }

    /// The app bundle's models.
    public static let main = ModelCatalog(bundle: .main)

    /// The bundled model for `variant`: a pre-compiled `.mlmodelc` if present, else the
    /// `.mlpackage` (compiled at load), else `nil`.
    public func modelURL(for variant: any GameVariant) -> URL? {
        let name = variant.modelResourceName
        return locate(name, "mlmodelc") ?? locate(name, "mlpackage")
    }

    /// Whether `variant` has a bundled model, i.e. can be played against the AI.
    public func isAvailable(_ variant: any GameVariant) -> Bool {
        modelURL(for: variant) != nil
    }

    /// The registered variants that can be played against the AI.
    public var availableVariantIDs: [String] {
        GameVariants.all.filter(isAvailable).map(\.id)
    }

    /// Load `config.variant`'s model and wrap it in an `Agent`, or `nil` when the model
    /// is missing or fails to load.
    public func makeAgent(config: GameConfig = .standard) -> Agent? {
        guard let url = modelURL(for: config.variant) else { return nil }
        let compiled: URL?
        if url.pathExtension == "mlmodelc" {
            compiled = url
        } else {
            compiled = try? MLModel.compileModel(at: url)
        }
        guard let compiled, let model = try? MLModel(contentsOf: compiled) else { return nil }
        return Agent(model: model, config: config)
    }
}

/// The persisted variant choice (#143): the `GameVariant.id` stored under one
/// `UserDefaults` key. Unknown or missing ids (a fresh install, a value from a newer
/// build) fall back to Plakoto, the app's default.
public enum VariantPreference {
    public static let key = "settings.variant"

    public static func load(from defaults: UserDefaults = .standard) -> any GameVariant {
        defaults.string(forKey: key).flatMap(GameVariants.variant(forID:)) ?? GameVariants.plakoto
    }

    public static func save(_ variant: any GameVariant, to defaults: UserDefaults = .standard) {
        defaults.set(variant.id, forKey: key)
    }
}
