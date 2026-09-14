import MMImport
import LedgerCore
import Testing

@Test func importerReferencesCanonicalSchema() {
    #expect(ImportCapability.canonicalSchemaVersion == CanonicalLedgerSchema.version)
}
