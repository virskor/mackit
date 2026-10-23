import SwiftUI

/// Small category icon at the start of a row: uniform font size and placeholder width, keeping multi-line text left-aligned.
struct CategoryIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 13
    var width: CGFloat = 18

    init(symbol: String, tint: Color, size: CGFloat = 13, width: CGFloat = 18) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
        self.width = width
    }

    init(category: JunkCategory, size: CGFloat = 13, width: CGFloat = 18) {
        self.init(symbol: category.symbol, tint: category.tint, size: size, width: width)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: width)
    }
}
