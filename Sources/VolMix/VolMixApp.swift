import SwiftUI

@main
struct VolMixApp: App {
    @StateObject private var model = MixerModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model).environmentObject(model.meeting).environmentObject(updater)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}
