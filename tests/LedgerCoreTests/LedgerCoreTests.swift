import LedgerCore
import MMImport
import MMFixtures
import Testing

@Test func capabilityVersionsMatchCanonicalSchema() {
    #expect(LedgerCoreVersion.current == CanonicalLedgerSchema.version)
    #expect(ImportCapability.canonicalSchemaVersion == CanonicalLedgerSchema.version)
    #expect(FixtureCapability.canonicalSchemaVersion == CanonicalLedgerSchema.version)
}
