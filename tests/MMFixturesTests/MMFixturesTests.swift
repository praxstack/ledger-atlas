import MMFixtures
import LedgerCore
import Testing

@Test func fixturesReferenceCanonicalSchema() {
    #expect(FixtureCapability.canonicalSchemaVersion == CanonicalLedgerSchema.version)
}
