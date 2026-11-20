import SwiftUI
import Combine

/// Drop-in replacement for @State.
///
/// The Command Line Tools SDK (macOS 26+) declares SwiftUI's @State as an
/// external macro whose plugin (libSwiftUIMacros) only ships with full Xcode.
/// Because Tauge is built with SwiftPM + CLT only, view-local state is backed
/// by a StateObject box instead, which keeps identical value semantics while
/// avoiding the missing macro plugin.
@propertyWrapper
public struct ViewState<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    public init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    public init(initialValue: Value) {
        _box = StateObject(wrappedValue: Box(initialValue))
    }

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
