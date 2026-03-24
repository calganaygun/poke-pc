import Foundation

enum RuntimeStatus: Equatable {
  case idle
  case preparing
  case pullingImage(progress: Double?)
  case creatingContainer
  case booting
  case healthy
  case stopping
  case degraded(reason: String)
  case failed(reason: String)

  var isWorking: Bool {
    switch self {
    case .preparing, .pullingImage, .creatingContainer, .booting, .stopping:
      return true
    default:
      return false
    }
  }

  var title: String {
    switch self {
    case .idle:
      return "Not Running"
    case .preparing:
      return "Preparing Runtime"
    case .pullingImage:
      return "Downloading Runtime"
    case .creatingContainer:
      return "Creating Container"
    case .booting:
      return "Booting Services"
    case .healthy:
      return "Healthy"
    case .stopping:
      return "Stopping"
    case .degraded:
      return "Degraded"
    case .failed:
      return "Failed"
    }
  }
}
