import SwiftUI
import UIKit

/// A space's picture cropped to a circle, or its colour when it has none,
/// as on the Mac's space rail.
struct SpaceIcon: View {
    let space: Space
    let size: CGFloat

    var body: some View {
        Group {
            if let data = space.imageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                space.color
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
