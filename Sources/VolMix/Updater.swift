import AppKit
import Sparkle

/// Atualização automática com o Sparkle.
///
/// O app procura atualizações sozinho uma vez por dia (SUScheduledCheckInterval no Info.plist) no
/// appcast.xml publicado junto com cada release do GitHub. Cada atualização é aceita só se tiver a
/// assinatura EdDSA da chave do projeto (SUPublicEDKey) e a mesma assinatura Developer ID do app.
///
/// Como o DeadNoise vive na barra de menus, sem janela, a procura automática não abre a janela do
/// Sparkle de surpresa: o menu ganha um aviso "Atualização disponível" e a janela abre quando a pessoa clica.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    /// Versão encontrada pela procura automática e ainda não vista. Mostrada como aviso no menu.
    @Published private(set) var pendingVersion: String?
    @Published private(set) var canCheck = false
    @Published var automaticallyDownloads = false {
        didSet {
            if controller.updater.automaticallyDownloadsUpdates != automaticallyDownloads {
                controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads
            }
        }
    }

    private var controller: SPUStandardUpdaterController!
    private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        // Sem feed configurado (build de desenvolvimento sem Info.plist completo), o Sparkle reclamaria ao iniciar.
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(startingUpdater: configured, updaterDelegate: nil, userDriverDelegate: self)
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    /// "Procurar atualizações…" e o clique no aviso do menu: abre a janela do Sparkle.
    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate (lembretes discretos para apps sem janela)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Só deixa o Sparkle abrir a janela na hora se o app acabou de ser aberto pela pessoa.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in
            if !state.userInitiated { self.pendingVersion = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.pendingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.pendingVersion = nil }
    }
}
