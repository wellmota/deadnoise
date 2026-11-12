import SwiftUI

@main
struct VolMixApp: App {
    @StateObject private var model = MixerModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model).environmentObject(model.meeting)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}
