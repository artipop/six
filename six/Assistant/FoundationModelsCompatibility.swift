import Foundation

/// The macOS 27 betas have shipped several ABI-incompatible revisions of the Foundation Models
/// executor API (`LanguageModelExecutorGenerationChannel`). Third-party `LanguageModel`s such as
/// Claude are compiled against the SDK's revision; if the running OS has a different one, calling
/// them crashes on a missing symbol. FoundationModels is weak-linked so we can detect this at runtime.
enum FoundationModelsCompatibility {
    /// A symbol every third-party executor needs: `LanguageModelExecutorGenerationChannel.send(_:)`
    /// as mangled by the SDK this app was built with (macOS 27 SDK 26A5406c, FoundationModels 2.0.68).
    private static let probeSymbol =
        "$s16FoundationModels38LanguageModelExecutorGenerationChannelV4sendyyAC5EventVYaF"

    /// `true` when the OS's Foundation Models runtime matches the SDK's executor ABI.
    static let supportsThirdPartyModels: Bool = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, probeSymbol) != nil
    }()

    static let mismatchExplanation =
        "This macOS build ships a Foundation Models runtime that doesn't match the SDK this app was built with " +
        "(\(ProcessInfo.processInfo.operatingSystemVersionString)). Rebuild with the Xcode whose SDK matches the OS beta to use remote models."
}
