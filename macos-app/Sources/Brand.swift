import SwiftUI

enum Brand {
  static let background = LinearGradient(
    colors: [
      Color(red: 0.98, green: 0.95, blue: 0.91),
      Color(red: 0.93, green: 0.96, blue: 0.98)
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let panel = LinearGradient(
    colors: [
      Color.white.opacity(0.86),
      Color.white.opacity(0.72)
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
}
