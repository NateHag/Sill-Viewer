import SwiftUI

/// Sill Desktop Host addition: `@State` without the SwiftUI macro.
///
/// In newer SDKs `@State` is a macro whose plugin ships only with Xcode, so a Mac with just the
/// Command Line Tools cannot build it. This wrapper holds a plain `State` value, which SwiftUI
/// finds and manages the same way (a DynamicProperty's stored properties are its storage).
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
