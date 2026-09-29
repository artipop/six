import Foundation

/// The language model Savoia runs on this Mac for small jobs nobody watches, outside the AI switch.
nonisolated enum LocalModelChoice: String, CaseIterable, Identifiable, Sendable {
    case gemma3
    case qwen25
    case gemma4

    var id: String { rawValue }

    var repository: String {
        switch self {
        case .gemma3: "mlx-community/gemma-3-1b-it-qat-4bit"
        case .qwen25: "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        case .gemma4: "mlx-community/gemma-4-e2b-it-4bit"
        }
    }

    var name: String {
        switch self {
        case .gemma3: "Gemma 3 1B"
        case .qwen25: "Qwen 2.5 1.5B"
        case .gemma4: "Gemma 4 E2B"
        }
    }

    var title: String {
        switch self {
        case .gemma3: String(localized: "\(name) — 770 MB")
        case .qwen25: String(localized: "\(name) — 870 MB")
        case .gemma4: String(localized: "\(name) — 3.6 GB")
        }
    }

    static let standard = LocalModelChoice.gemma3
}

/// What decides which group a tab goes into.
nonisolated enum TabSortingMethod: String, CaseIterable, Identifiable, Sendable {
    case embeddings
    case languageModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embeddings: String(localized: "Embeddings")
        case .languageModel: String(localized: "Local Model")
        }
    }
}

extension ConfigurationStore {
    var tabSorting: TabSortingMethod {
        get { self[.tabSorting].flatMap(TabSortingMethod.init(rawValue:)) ?? .embeddings }
        set { self[.tabSorting] = newValue.rawValue }
    }

    var localModel: LocalModelChoice {
        get { self[.localModel].flatMap(LocalModelChoice.init(rawValue:)) ?? .standard }
        set { self[.localModel] = newValue.rawValue }
    }
}
