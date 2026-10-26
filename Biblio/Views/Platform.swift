import SwiftUI

extension View {
    /// Minimum window/sheet size on macOS. iOS sizes sheets to the device, and a minimum
    /// wider than a small iPhone (375 pt on an iPhone 13 mini) would push content off screen.
    func macMinFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }
}
