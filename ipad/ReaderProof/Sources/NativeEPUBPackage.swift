import Foundation

struct NativeEPUBPackage: Sendable {
  let path: [NativeCFIStep]

  static func resolve(_ source: NativeEPUBSource, info: EpubBookInfo, idref: String) throws -> Self
  {
    let namespace = "http://www.idpf.org/2007/opf"
    guard source.elements[0].name == "package", source.elements[0].namespace == namespace,
      let spine = source.elements[0].children.compactMap({ child -> Int? in
        if case .element(let index, _) = child,
          source.elements[index].name == "spine", source.elements[index].namespace == namespace
        {
          return index
        }
        return nil
      }).first
    else { throw NativeEPUBError.invalidPublication }
    let itemrefs = source.elements[spine].children.compactMap { child -> Int? in
      if case .element(let index, _) = child,
        source.elements[index].name == "itemref", source.elements[index].namespace == namespace
      {
        return index
      }
      return nil
    }
    guard itemrefs.count == info.spine.count,
      zip(itemrefs, info.spine).allSatisfy({ index, item in
        let attributes = source.elements[index].attributes
        return attributes["idref"] == item.idref && (attributes["linear"] != "no") == item.linear
      }),
      itemrefs.filter({ source.elements[$0].attributes["idref"] == idref }).count == 1,
      let item = itemrefs.first(where: { source.elements[$0].attributes["idref"] == idref })
    else { throw NativeEPUBError.invalidPublication }
    return Self(path: try source.path(to: item))
  }

  func validate(_ cfi: NativeEPUBCFI) throws {
    guard cfi.package.count == path.count,
      zip(cfi.package, path).allSatisfy({ supplied, actual in
        supplied.index == actual.index
          && (supplied.assertion == nil || supplied.assertion == actual.assertion)
      })
    else { throw NativeEPUBError.invalidAnchor }
  }
}
