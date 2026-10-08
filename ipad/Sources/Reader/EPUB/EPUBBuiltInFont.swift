enum EPUBBuiltInFont: String, CaseIterable, Identifiable {
  case publisher = ""
  case serif = "serif"
  case sansSerif = "sans-serif"
  case monospace = "monospace"
  case georgia = "Georgia"
  case helvetica = "Helvetica"
  case palatino = "Palatino"
  case timesNewRoman = "Times New Roman"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .publisher: "Publisher font"
    case .serif: "Serif"
    case .sansSerif: "Sans serif"
    case .monospace: "Monospace"
    case .georgia, .helvetica, .palatino, .timesNewRoman: rawValue
    }
  }
}
