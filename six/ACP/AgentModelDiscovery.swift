#if os(macOS)
import Foundation
import Observation

/// A separate, prompt-free session discovers models without changing the active conversation.
///
/// Asking is a process spawned and a full ACP handshake run just to read a list of names off it, so
/// `catalogs` starts from whatever `store` last saved rather than empty — a picker opened again, or
/// six relaunched, shows the answer from before while `refresh` only runs again for an agent that has
/// never answered at all. `forget` is the one place that throws a saved answer away on purpose.
@MainActor @Observable
final class AgentModelDiscovery {
    @ObservationIgnored private let store: ConfigurationStore

    private(set) var catalogs: [String: AgentModels]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]

    init(store: ConfigurationStore) {
        self.store = store
        catalogs = store.agentModelCatalogs
    }

    func forget(_ agent: ACPAgentDefinition) {
        catalogs[agent.id] = nil
        errors[agent.id] = nil
        var saved = store.agentModelCatalogs
        saved[agent.id] = nil
        store.agentModelCatalogs = saved
    }

    func refresh(_ agent: ACPAgentDefinition, toolchain: AgentToolchain, directory: URL) async {
        guard loading.insert(agent.id).inserted else { return }
        errors[agent.id] = nil
        defer { loading.remove(agent.id) }
        do {
            try Task.checkCancellation()
            let delegate = DiscoveryDelegate()
            let client = try await ACPClient(definition: toolchain.launchDefinition(for: agent),
                                             delegate: delegate, allowsFileAccess: false)
            // Closing the transport also resolves pending JSON-RPC continuations on timeout.
            let deadline = Task {
                try await Task.sleep(for: .seconds(30))
                await client.shutdown()
            }
            defer { deadline.cancel() }
            do {
                let catalog = try await withTaskCancellationHandler {
                    _ = try await client.initialize()
                    let session = try await client.newSession(cwd: directory)
                    try Task.checkCancellation()
                    return AgentModels(configOptions: session.configOptions, models: session.models)
                } onCancel: {
                    Task { await client.shutdown() }
                }
                await client.shutdown()
                catalogs[agent.id] = catalog
                var saved = store.agentModelCatalogs
                saved[agent.id] = catalog
                store.agentModelCatalogs = saved
                if catalog.choices.isEmpty {
                    errors[agent.id] = String(localized: "This agent did not provide a model list. Its default model will be used.")
                }
            } catch {
                await client.shutdown()
                throw error
            }
        } catch {
            if !Task.isCancelled { errors[agent.id] = error.localizedDescription }
        }
    }
}

private final class DiscoveryDelegate: ACPClientDelegate, Sendable {
    func client(_ client: ACPClient, didReceive notification: ACP.SessionNotification) async {}
    func client(_ client: ACPClient, requestPermission request: ACP.RequestPermissionRequest) async -> ACP.RequestPermissionOutcome {
        .cancelled
    }
}
#endif
