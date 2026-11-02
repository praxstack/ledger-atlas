import Foundation
import Testing

@testable import LedgerCore

/// A synthetic ZIP written by Python's zipfile: a fixed-Huffman entry, a dynamic-Huffman entry,
/// a stored block inside DEFLATE, and a directory entry.
private let deflatedFixture = Data(
  base64Encoded: [
    "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",
    "AAAAAA==",
  ].joined())!

private func syntheticRows() -> Data {
  Data(
    (0..<400).map { String(format: "row %d,amount %d.%02d\n", $0, $0 * 7 % 1000, $0 % 100) }
      .joined().utf8)
}

@Test func archiveReadsEveryDeflateBlockType() throws {
  let entries = try XLSXArchive.read(deflatedFixture)
  #expect(entries.keys.sorted() == ["dynamic.txt", "fixed.txt", "stored-block.txt"])
  #expect(entries["fixed.txt"] == Data("abcabcabc ledger".utf8))
  #expect(entries["dynamic.txt"] == syntheticRows())
  #expect(entries["stored-block.txt"] == Data("stored inside deflate".utf8))
}

@Test func archiveWritesDeterministicStoredZipsThatReadBack() throws {
  let entries: [(name: String, data: Data)] = [
    ("a.txt", Data("alpha".utf8)), ("dir/b.bin", Data((0..<300).map { UInt8($0 % 256) })),
    ("empty", Data()),
  ]
  let archive = try XLSXArchive.write(entries)
  #expect(try XLSXArchive.write(entries) == archive)
  let read = try XLSXArchive.read(archive)
  #expect(read.count == 3)
  for entry in entries { #expect(read[entry.name] == entry.data) }
  #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
}

@Test func archiveRefusesUnsafeDamagedAndOversizedInput() throws {
  #expect(throws: XLSXArchive.Error.notAnArchive) { try XLSXArchive.read(Data("not a zip".utf8)) }
  for name in ["../escape", "/absolute", "a//b", "a\\b", "./a"] {
    #expect(throws: XLSXArchive.Error.unsafeEntryName(name)) {
      try XLSXArchive.write([(name, Data())])
    }
  }
  #expect(throws: XLSXArchive.Error.duplicateEntry("a")) {
    try XLSXArchive.write([("a", Data()), ("a", Data())])
  }

  var flipped = try XLSXArchive.write([("a.txt", Data("abc".utf8))])
  flipped[30 + 5] ^= 0xFF  // the first payload byte, after the local header and name
  #expect(throws: XLSXArchive.Error.damaged("a.txt")) { try XLSXArchive.read(flipped) }

  let whole = try XLSXArchive.write([("a.txt", Data("abc".utf8))])
  #expect(throws: XLSXArchive.Error.notAnArchive) { try XLSXArchive.read(whole.dropLast(3)) }

  let tight = XLSXArchive.Limits(maximumEntries: 10, maximumEntryBytes: 100, maximumTotalBytes: 1_000)
  #expect(throws: XLSXArchive.Error.tooLarge) { try XLSXArchive.read(deflatedFixture, limits: tight) }
}

@Test func archiveSurvivesRandomCorruptionWithoutCrashing() throws {
  var generator = SeededGenerator(seed: 0x1ed6e2)
  let workbook = try XLSXWorkbook(sheets: [
    .init(name: "Data", rows: [["a", "b"], ["1", "2"]])
  ]).xlsxData()
  for base in [deflatedFixture, workbook] {
    for _ in 0..<500 {
      var data = base
      for _ in 0..<Int.random(in: 1...4, using: &generator) {
        data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(
          in: 0...255, using: &generator)
      }
      _ = try? XLSXWorkbook(xlsxData: data)
      _ = try? XLSXArchive.read(data)
    }
  }
}

@Test func workbookRoundTripsAwkwardTextExactly() throws {
  let awkward = [
    "", "0012.50", "1E3", "2026-01-02", "a&b<c>\"d'", "tab\there", "cr\r\nlf", "control\u{1}x",
    "_x0041_ stays literal", "  padded  ", "₹ 😀 Ünïcode", "=SUM(A1)",
  ]
  let workbook = XLSXWorkbook(sheets: [
    .init(name: "Data", rows: [["first", "second"], awkward, [], ["after a gap"]]),
    .init(name: "Empty", rows: []),
  ])
  let data = try workbook.xlsxData()
  #expect(try workbook.xlsxData() == data)
  let read = try XLSXWorkbook(xlsxData: data)
  #expect(read.sheets.map(\.name) == ["Data", "Empty"])
  #expect(read.sheet(named: "Data")?.rows == [["first", "second"], awkward, [], ["after a gap"]])
  #expect(read.sheet(named: "Empty")?.rows == [])
}

@Test func workbookRejectsBadSheetNames() {
  for name in ["", "a/b", "a[1]", "what?", "'quoted'", String(repeating: "x", count: 32)] {
    #expect(throws: XLSXWorkbook.Error.invalidSheetName(name)) {
      try XLSXWorkbook(sheets: [.init(name: name, rows: [])]).xlsxData()
    }
  }
  #expect(throws: XLSXWorkbook.Error.duplicateSheet("data")) {
    try XLSXWorkbook(sheets: [.init(name: "Data", rows: []), .init(name: "data", rows: [])])
      .xlsxData()
  }
}

/// A workbook shaped like what spreadsheet apps save: shared strings with rich-text runs and
/// phonetic hints, numbers, booleans, gaps, and namespaced relationship ids.
private func appSavedWorkbook(sheet: String, extraParts: [(String, String)] = []) throws -> Data {
  let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  let rels = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  let package = "http://schemas.openxmlformats.org/package/2006/relationships"
  var parts: [(String, String)] = [
    (
      "xl/workbook.xml",
      "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rels)\"><sheets><sheet name=\"Ledger\" sheetId=\"7\" r:id=\"rId3\"/></sheets></workbook>"
    ),
    (
      "xl/_rels/workbook.xml.rels",
      "<Relationships xmlns=\"\(package)\"><Relationship Id=\"rId3\" Type=\"\(rels)/worksheet\" Target=\"/xl/worksheets/ledger.xml\"/><Relationship Id=\"rId9\" Type=\"\(rels)/hyperlink\" Target=\"https://example.invalid\" TargetMode=\"External\"/></Relationships>"
    ),
    (
      "xl/sharedStrings.xml",
      "<sst xmlns=\"\(main)\"><si><t>plain</t></si><si><r><t>rich </t></r><r><rPr><b/></rPr><t>text</t></r><rPh><t>ignored</t></rPh></si><si><t xml:space=\"preserve\">  kept  </t></si></sst>"
    ),
    ("xl/worksheets/ledger.xml", sheet),
  ]
  parts += extraParts
  return try XLSXArchive.write(parts.map { ($0.0, Data($0.1.utf8)) })
}

@Test func workbookReadsWhatSpreadsheetAppsSave() throws {
  let sheet = """
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>\
    <row r="3"><c r="B3"><v>12.5</v></c><c r="C3" t="b"><v>1</v></c><c t="s"><v>2</v></c></row>\
    <row><c t="str"><v>after</v></c></row>\
    </sheetData></worksheet>
    """
  let read = try XLSXWorkbook(xlsxData: appSavedWorkbook(sheet: sheet))
  #expect(read.sheets.map(\.name) == ["Ledger"])
  #expect(
    read.sheets[0].rows == [
      ["plain", "", "rich text"], [], ["", "12.5", "TRUE", "  kept  "], ["after"],
    ])
}

@Test func workbookRefusesCellsWhoseValueCannotBeTrusted() throws {
  func sheet(_ cells: String, tail: String = "") -> String {
    "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\">\(cells)</row></sheetData>\(tail)</worksheet>"
  }
  #expect(throws: XLSXWorkbook.Error.formulaCell(sheet: "Ledger", cell: "B1")) {
    try XLSXWorkbook(xlsxData: appSavedWorkbook(sheet: sheet("<c r=\"B1\"><f>1+1</f><v>2</v></c>")))
  }
  #expect(throws: XLSXWorkbook.Error.errorCell(sheet: "Ledger", cell: "A1")) {
    try XLSXWorkbook(xlsxData: appSavedWorkbook(sheet: sheet("<c r=\"A1\" t=\"e\"><v>#REF!</v></c>")))
  }
  #expect(throws: XLSXWorkbook.Error.mergedCells(sheet: "Ledger")) {
    try XLSXWorkbook(
      xlsxData: appSavedWorkbook(
        sheet: sheet(
          "<c r=\"A1\" t=\"s\"><v>0</v></c>",
          tail: "<mergeCells count=\"1\"><mergeCell ref=\"A1:B1\"/></mergeCells>")))
  }
  #expect(throws: XLSXWorkbook.Error.invalidCellReference(sheet: "Ledger", cell: "A1")) {
    try XLSXWorkbook(xlsxData: appSavedWorkbook(sheet: sheet("<c r=\"A1\" t=\"s\"><v>99</v></c>")))
  }
  #expect(throws: XLSXWorkbook.Error.invalidCellReference(sheet: "Ledger", cell: "A2")) {
    try XLSXWorkbook(xlsxData: appSavedWorkbook(sheet: sheet("<c r=\"A2\"><v>1</v></c>")))
  }
  #expect(throws: XLSXWorkbook.Error.invalidCellReference(sheet: "Ledger", cell: "A1")) {
    try XLSXWorkbook(
      xlsxData: appSavedWorkbook(sheet: sheet("<c r=\"A1\"><v>1</v></c><c r=\"A1\"><v>2</v></c>")))
  }
  let entity = """
    <?xml version="1.0"?><!DOCTYPE worksheet [<!ENTITY boom "boom">]>\
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>
    """
  #expect(throws: XLSXWorkbook.Error.malformedXML("Ledger")) {
    try XLSXWorkbook(xlsxData: appSavedWorkbook(sheet: entity))
  }
}

@Test func cellReferencesConvertBothWays() {
  #expect(XLSXWorkbook.columnName(0) == "A")
  #expect(XLSXWorkbook.columnName(25) == "Z")
  #expect(XLSXWorkbook.columnName(26) == "AA")
  #expect(XLSXWorkbook.columnName(16_383) == "XFD")
  #expect(XLSXWorkbook.position(of: "C7").map { [$0.row, $0.column] } == [6, 2])
  #expect(XLSXWorkbook.position(of: "XFD1048576").map { [$0.row, $0.column] } == [1_048_575, 16_383])
  for bad in ["XFE1", "A0", "1A", "A", "a1", "A1048577", ""] {
    #expect(XLSXWorkbook.position(of: bad) == nil)
  }
}

/// Deterministic randomness so the corruption test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
