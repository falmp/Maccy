import Foundation
import Defaults

enum StepType: String, Codable, CaseIterable, Identifiable {
  case upperCase = "Upper Case"
  case lowerCase = "Lower Case"
  case titleCase = "Title Case"
  case trim = "Trim"
  case removeNewlines = "Remove Newlines"
  case replace = "Replace"

  var id: String { self.rawValue }
}

struct TransformationStep: Codable, Identifiable, Hashable, Defaults.Serializable {
  var id = UUID()
  var type: StepType
  var search: String = ""
  var replacement: String = ""
  var caseInsensitive: Bool = false

  func apply(to text: String) -> String {
    switch type {
    case .upperCase: return text.uppercased()
    case .lowerCase: return text.lowercased()
    case .titleCase: return text.capitalized
    case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
    case .removeNewlines: return text.replacingOccurrences(of: "\n", with: " ")
    case .replace:
      if caseInsensitive {
        return text.replacingOccurrences(of: search, with: replacement, options: .caseInsensitive)
      } else {
        return text.replacingOccurrences(of: search, with: replacement)
      }
    }
  }
}

struct Transformation: Codable, Identifiable, Hashable, Defaults.Serializable {
  var id = UUID()
  var name: String
  var steps: [TransformationStep] = []
  var shortcut: String?

  func apply(to text: String) -> String {
    var result = text
    for step in steps {
      result = step.apply(to: result)
    }
    return result
  }
}
