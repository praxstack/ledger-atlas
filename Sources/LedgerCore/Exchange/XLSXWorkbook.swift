import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// A workbook of plain text grids: the shape Ledger Atlas exchanges as XLSX.
///
/// Every cell is text. Writing uses inline strings, so the file needs no shared-string table
/// and numbers keep their exact decimal literals. Reading accepts what spreadsheet apps write
/// back (shared strings, numbers, booleans) and refuses formulas, error cells and merged
/// cells, because their values cannot be trusted as data.
public struct XLSXWorkbook: Equatable, Sendable {
  public struct Sheet: Equatable, Sendable {
    public var name: String
    /// Rows of cells, top to bottom. Trailing empty cells and rows are not significant.
    public var rows: [[String]]

    public init(name: String, rows: [[String]]) {
      self.name = name
      self.rows = rows
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case invalidSheetName(String)
    case duplicateSheet(String)
    case missingPart(String)
    case malformedXML(String)
    case formulaCell(sheet: String, cell: String)
    case errorCell(sheet: String, cell: String)
    case mergedCells(sheet: String)
    case invalidCellReference(sheet: String, cell: String)
    case tooLarge
  }

  public var sheets: [Sheet]

  public init(sheets: [Sheet]) {
    self.sheets = sheets
  }

  public func sheet(named name: String) -> Sheet? { sheets.first { $0.name == name } }

  /// Largest grid accepted on read, to keep a hostile file from exhausting memory.
  static let maximumColumns = 16_384
  static let maximumRows = 1_048_576

  // MARK: Writing

  public func xlsxData() throws -> Data {
    var seen: Set<String> = []
    for sheet in sheets {
      guard Self.isValidSheetName(sheet.name) else { throw Error.invalidSheetName(sheet.name) }
      guard seen.insert(sheet.name.lowercased()).inserted else {
        throw Error.duplicateSheet(sheet.name)
      }
    }
    var entries: [(name: String, data: Data)] = []
    let sheetNumbers = sheets.indices.map { $0 + 1 }
    entries.append(("[Content_Types].xml", Data(contentTypes(sheetNumbers).utf8)))
    entries.append(("_rels/.rels", Data(Self.rootRelationships.utf8)))
    entries.append(("xl/workbook.xml", Data(workbookXML().utf8)))
    entries.append(("xl/_rels/workbook.xml.rels", Data(workbookRelationships(sheetNumbers).utf8)))
    entries.append(("xl/styles.xml", Data(Self.styles.utf8)))
    for (index, sheet) in sheets.enumerated() {
      entries.append(("xl/worksheets/sheet\(index + 1).xml", Data(Self.sheetXML(sheet).utf8)))
    }
    return try XLSXArchive.write(entries)
  }

  private func contentTypes(_ numbers: [Int]) -> String {
    let overrides = numbers.map {
      "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
    }.joined()
    return
      "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(overrides)</Types>"
  }

  private static let rootRelationships =
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"

  private static let styles =
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"49\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"

  private func workbookXML() -> String {
    let entries = sheets.enumerated().map { index, sheet in
      "<sheet name=\"\(Self.escape(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
    }.joined()
    return
      "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(entries)</sheets></workbook>"
  }

  private func workbookRelationships(_ numbers: [Int]) -> String {
    let sheetLinks = numbers.map {
      "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
    }.joined()
    let stylesID = (numbers.last ?? 0) + 1
    return
      "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(sheetLinks)<Relationship Id=\"rId\(stylesID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"
  }

  /// Cells use the text number format (style 1) so a spreadsheet app keeps literals like
  /// "0012.50" or "2026-01-02" as typed instead of converting them.
  static func sheetXML(_ sheet: Sheet) -> String {
    var xml =
      "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
    for (rowIndex, row) in sheet.rows.enumerated() {
      xml += "<row r=\"\(rowIndex + 1)\">"
      for (columnIndex, value) in row.enumerated() where !value.isEmpty {
        let reference = columnName(columnIndex) + String(rowIndex + 1)
        xml +=
          "<c r=\"\(reference)\" s=\"1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
      }
      xml += "</row>"
    }
    return xml + "</sheetData></worksheet>"
  }

  /// Excel's sheet-name rules: 1 to 31 characters, none of `[]:*?/\`, not wrapped in quotes.
  static func isValidSheetName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 31 && !name.hasPrefix("'") && !name.hasSuffix("'")
      && name.allSatisfy { !"[]:*?/\\".contains($0) }
  }

  /// XML text with markup escaped. Characters XML 1.0 cannot carry use Excel's `_xHHHH_`
  /// escape, and a literal `_xHHHH_` is protected the same way, so every string round-trips.
  static func escape(_ text: String) -> String {
    var result = ""
    var scalars = Array(text.unicodeScalars)[...]
    while let scalar = scalars.first {
      if scalar == "_", isExcelEscape(scalars) {
        result += "_x005F_"
        scalars = scalars.dropFirst()
        continue
      }
      switch scalar {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "\t", "\n": result.unicodeScalars.append(scalar)
      case "\r": result += "&#13;"
      default:
        if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF {
          result += String(format: "_x%04X_", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
      scalars = scalars.dropFirst()
    }
    return result
  }

  private static func isExcelEscape(_ scalars: ArraySlice<Unicode.Scalar>) -> Bool {
    let candidate = Array(scalars.prefix(7))
    guard candidate.count == 7, candidate[1] == "x", candidate[6] == "_" else { return false }
    return candidate[2...5].allSatisfy { $0.properties.isASCIIHexDigit }
  }

  /// Reverses `escape`'s `_xHHHH_` sequences.
  static func unescapeExcel(_ text: String) -> String {
    guard text.contains("_x") else { return text }
    var result = String.UnicodeScalarView()
    var scalars = Array(text.unicodeScalars)[...]
    while let scalar = scalars.first {
      if scalar == "_", isExcelEscape(scalars),
        let value = UInt32(String(String.UnicodeScalarView(scalars.dropFirst(2).prefix(4))), radix: 16),
        let decoded = Unicode.Scalar(value)
      {
        result.append(decoded)
        scalars = scalars.dropFirst(7)
      } else {
        result.append(scalar)
        scalars = scalars.dropFirst()
      }
    }
    return String(result)
  }

  /// "A", "B", … "Z", "AA", … for a zero-based column.
  static func columnName(_ index: Int) -> String {
    var number = index + 1
    var name = ""
    while number > 0 {
      let remainder = (number - 1) % 26
      name = String(UnicodeScalar(UInt8(65 + remainder))) + name
      number = (number - 1) / 26
    }
    return name
  }

  /// Zero-based (row, column) for a reference like "B12".
  static func position(of reference: String) -> (row: Int, column: Int)? {
    var column = 0
    var rowDigits = ""
    for character in reference {
      if rowDigits.isEmpty, let ascii = character.asciiValue, (65...90).contains(ascii) {
        column = column * 26 + Int(ascii - 64)
        guard column <= maximumColumns else { return nil }
      } else if character.isASCII, character.isNumber {
        rowDigits.append(character)
      } else {
        return nil
      }
    }
    guard column > 0, let row = Int(rowDigits), row >= 1, row <= maximumRows else { return nil }
    return (row - 1, column - 1)
  }

  // MARK: Reading

  public init(xlsxData data: Data, limits: XLSXArchive.Limits = XLSXArchive.Limits()) throws {
    let parts = try XLSXArchive.read(data, limits: limits)
    guard let workbook = parts["xl/workbook.xml"] else { throw Error.missingPart("xl/workbook.xml") }
    let declared = try WorkbookParser.parse(workbook)
    var targets: [String: String] = [:]
    if let relationships = parts["xl/_rels/workbook.xml.rels"] {
      targets = try RelationshipParser.parse(relationships)
    }
    let shared = try parts["xl/sharedStrings.xml"].map(SharedStringParser.parse) ?? []

    var seen: Set<String> = []
    var sheets: [Sheet] = []
    for (name, relationshipID) in declared {
      guard seen.insert(name.lowercased()).inserted else { throw Error.duplicateSheet(name) }
      guard let target = targets[relationshipID] else { throw Error.missingPart(name) }
      let path =
        target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
      guard let xml = parts[path] else { throw Error.missingPart(path) }
      sheets.append(Sheet(name: name, rows: try SheetParser.parse(xml, sheet: name, shared: shared)))
    }
    self.sheets = sheets
  }
}

// MARK: - Parsers

/// Shared plumbing: a delegate that records the first problem and aborts.
private class StrictParser: NSObject, XMLParserDelegate {
  var failure: Swift.Error?

  func run(_ data: Data, part: String) throws {
    // OOXML parts never carry a DTD. Refusing one up front rules out entity expansion
    // attacks whatever the platform parser would do with them.
    if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
      throw XLSXWorkbook.Error.malformedXML(part)
    }
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = false
    parser.shouldResolveExternalEntities = false
    parser.delegate = self
    let ok = parser.parse()
    if let failure { throw failure }
    guard ok else { throw XLSXWorkbook.Error.malformedXML(part) }
  }

  func fail(_ error: Swift.Error, _ parser: XMLParser) {
    if failure == nil { failure = error }
    parser.abortParsing()
  }

  // Subclasses override these. They are declared here so the protocol witnesses dispatch
  // to the subclass on Linux too, where XMLParserDelegate is a plain Swift protocol.
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {}

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {}

  func parser(_ parser: XMLParser, foundCharacters string: String) {}

}

/// Element names without any namespace prefix.
private func local(_ name: String) -> String {
  name.split(separator: ":").last.map(String.init) ?? name
}

private final class WorkbookParser: StrictParser {
  var sheets: [(String, String)] = []

  static func parse(_ data: Data) throws -> [(String, String)] {
    let parser = WorkbookParser()
    try parser.run(data, part: "xl/workbook.xml")
    return parser.sheets
  }

  override func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    guard local(elementName) == "sheet" else { return }
    let id = attributes.first { local($0.key) == "id" && $0.key != "sheetId" }?.value
    guard let name = attributes["name"], let id else {
      return fail(XLSXWorkbook.Error.malformedXML("xl/workbook.xml"), parser)
    }
    sheets.append((name, id))
  }
}

private final class RelationshipParser: StrictParser {
  var targets: [String: String] = [:]

  static func parse(_ data: Data) throws -> [String: String] {
    let parser = RelationshipParser()
    try parser.run(data, part: "xl/_rels/workbook.xml.rels")
    return parser.targets
  }

  override func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    guard local(elementName) == "Relationship", let id = attributes["Id"],
      let target = attributes["Target"]
    else { return }
    if attributes["TargetMode"] == "External" { return }
    targets[id] = target
  }
}

private final class SharedStringParser: StrictParser {
  var strings: [String] = []
  var current: String?
  var inText = false
  var inPhonetic = false

  static func parse(_ data: Data) throws -> [String] {
    let parser = SharedStringParser()
    try parser.run(data, part: "xl/sharedStrings.xml")
    return parser.strings
  }

  override func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    switch local(elementName) {
    case "si":
      current = ""
      guard strings.count < XLSXWorkbook.maximumRows * 4 else {
        return fail(XLSXWorkbook.Error.tooLarge, parser)
      }
    case "rPh": inPhonetic = true
    case "t": inText = !inPhonetic
    default: break
    }
  }

  override func parser(_ parser: XMLParser, foundCharacters string: String) {
    if inText { current? += string }
  }

  override func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    switch local(elementName) {
    case "si":
      strings.append(XLSXWorkbook.unescapeExcel(current ?? ""))
      current = nil
    case "rPh": inPhonetic = false
    case "t": inText = false
    default: break
    }
  }
}

private final class SheetParser: StrictParser {
  let sheet: String
  let shared: [String]
  var cells: [Int: [Int: String]] = [:]
  var nextRow = 0
  var currentRow = 0
  var nextColumn = 0
  var cell: (row: Int, column: Int, reference: String, type: String)?
  var value = ""
  var capturing = false
  var inPhonetic = false

  init(sheet: String, shared: [String]) {
    self.sheet = sheet
    self.shared = shared
  }

  static func parse(_ data: Data, sheet: String, shared: [String]) throws -> [[String]] {
    let parser = SheetParser(sheet: sheet, shared: shared)
    try parser.run(data, part: sheet)
    guard let lastRow = parser.cells.keys.max() else { return [] }
    return (0...lastRow).map { row in
      guard let columns = parser.cells[row], let last = columns.keys.max() else { return [] }
      return (0...last).map { columns[$0] ?? "" }
    }
  }

  override func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    switch local(elementName) {
    case "row":
      if let text = attributes["r"] {
        guard let number = Int(text), number >= 1, number <= XLSXWorkbook.maximumRows else {
          return fail(XLSXWorkbook.Error.invalidCellReference(sheet: sheet, cell: text), parser)
        }
        currentRow = number - 1
      } else {
        currentRow = nextRow
      }
      nextRow = currentRow + 1
      nextColumn = 0
    case "c":
      var position = (row: currentRow, column: nextColumn)
      let reference = attributes["r"] ?? XLSXWorkbook.columnName(nextColumn) + String(currentRow + 1)
      if let text = attributes["r"] {
        guard let parsed = XLSXWorkbook.position(of: text), parsed.row == currentRow else {
          return fail(XLSXWorkbook.Error.invalidCellReference(sheet: sheet, cell: text), parser)
        }
        position = parsed
      }
      guard position.column < XLSXWorkbook.maximumColumns else {
        return fail(XLSXWorkbook.Error.tooLarge, parser)
      }
      nextColumn = position.column + 1
      let type = attributes["t"] ?? "n"
      if type == "e" {
        return fail(XLSXWorkbook.Error.errorCell(sheet: sheet, cell: reference), parser)
      }
      cell = (position.row, position.column, reference, type)
      value = ""
    case "f":
      let reference = cell?.reference ?? "?"
      fail(XLSXWorkbook.Error.formulaCell(sheet: sheet, cell: reference), parser)
    case "v":
      capturing = cell != nil
    case "rPh":
      inPhonetic = true
    case "t":
      capturing = cell != nil && !inPhonetic
    case "mergeCell":
      fail(XLSXWorkbook.Error.mergedCells(sheet: sheet), parser)
    default:
      break
    }
  }

  override func parser(_ parser: XMLParser, foundCharacters string: String) {
    if capturing { value += string }
  }

  override func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    switch local(elementName) {
    case "v", "t":
      capturing = false
    case "rPh":
      inPhonetic = false
    case "c":
      guard let current = cell else { return }
      cell = nil
      let text: String
      switch current.type {
      case "s":
        guard let index = Int(value), shared.indices.contains(index) else {
          return fail(
            XLSXWorkbook.Error.invalidCellReference(sheet: sheet, cell: current.reference), parser)
        }
        text = shared[index]
      case "inlineStr", "str":
        text = XLSXWorkbook.unescapeExcel(value)
      case "b":
        text = value == "1" ? "TRUE" : value == "0" ? "FALSE" : value
      default:
        text = value
      }
      guard !text.isEmpty else { return }
      if cells[current.row]?[current.column] != nil {
        return fail(
          XLSXWorkbook.Error.invalidCellReference(sheet: sheet, cell: current.reference), parser)
      }
      cells[current.row, default: [:]][current.column] = text
    default:
      break
    }
  }
}
