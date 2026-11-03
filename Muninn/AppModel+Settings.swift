import MuninnCore
import SwiftUI

extension AppModel {
    func settingsBinding<T>(_ keyPath: WritableKeyPath<MuninnCore.Settings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = self.settings
                updated[keyPath: keyPath] = newValue
                self.saveSettings(updated)
            }
        )
    }

    func updateSettings(_ change: (inout MuninnCore.Settings) -> Void) {
        var updated = settings
        change(&updated)
        saveSettings(updated)
    }
}
