import SwiftUI

/// Lets the Mac's menu bar know a text field currently has the keyboard.
///
/// The transport is on the space bar, because that is the key every music
/// application puts it on. AppKit offers a menu's key equivalents to the menu
/// before the field editor, so an always-enabled Play item would eat the space bar
/// in the middle of a release title. Disabling it while a field has focus lets the
/// keystroke through, and the shortcut still works everywhere else.
public struct EditingTextKey: FocusedValueKey {
    public typealias Value = Bool
}

public extension FocusedValues {
    var isEditingText: Bool? {
        get { self[EditingTextKey.self] }
        set { self[EditingTextKey.self] = newValue }
    }
}

public extension View {
    /// Publishes whether this view currently has text focus.
    func publishesTextEditing(_ isEditing: Bool) -> some View {
        focusedValue(\.isEditingText, isEditing)
    }
}
