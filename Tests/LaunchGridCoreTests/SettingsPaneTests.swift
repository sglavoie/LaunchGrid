import Foundation
import Testing
@testable import LaunchGridCore

struct SettingsPaneTests {
    private func names(_ q: String) -> [String] { SettingsPane.matches(q).map(\.name) }

    @Test func findsPanesByNameAndOtherWords() {
        #expect(names("bluetooth") == ["Bluetooth"])
        #expect(names("blue").first == "Bluetooth")
        #expect(names("dark mode") == ["Appearance"])
        #expect(names("wifi").first == "Wi-Fi")
        #expect(names("displ").first == "Displays")
        #expect(names("hot corners") == ["Desktop & Dock"])
        // A name ranks above another word for something else.
        #expect(names("sound").first == "Sound")
    }

    @Test func staysQuietForLooseMatches() {
        // One letter, or letters scattered through a name, find nothing.
        #expect(names("s").isEmpty)
        #expect(names("btth").isEmpty)
        #expect(names("zzzz").isEmpty)
        #expect(SettingsPane.matches("e", limit: 10).isEmpty)
        #expect(SettingsPane.matches("se", limit: 2).count <= 2)
    }

    @Test func idsAreSteadyAndDistinct() {
        let ids = SettingsPane.all.map(\.uuid)
        #expect(Set(ids).count == ids.count)
        #expect(Set(SettingsPane.all.map(\.id)).count == SettingsPane.all.count)
        // The same from run to run, so usage is remembered by it.
        #expect(SettingsPane.uuid(for: "com.apple.BluetoothSettings") == SettingsPane.uuid(for: "com.apple.BluetoothSettings"))
        let bluetooth = SettingsPane.all.first { $0.name == "Bluetooth" }!
        #expect(SettingsPane.pane(for: bluetooth.uuid) == bluetooth)
        #expect(bluetooth.action.kind == .openURL(template: "x-apple.systempreferences:com.apple.BluetoothSettings"))
        #expect(!bluetooth.action.showsOnGrid)
    }

    @Test func keepsOnlyThePanesThisMacHas() {
        #expect(SettingsPane.available(in: []).count == SettingsPane.all.count)
        #expect(SettingsPane.available(in: ["com.apple.BluetoothSettings", "com.example.nothing"]).map(\.name) == ["Bluetooth"])
    }
}
