import SwiftUI

/// SwiftUI declares both a `State` property wrapper and a `State` macro; the macro's plugin is not shipped with the Command Line Tools, so `@State` fails to compile there.
typealias ViewState<Value> = SwiftUICore.State<Value>
