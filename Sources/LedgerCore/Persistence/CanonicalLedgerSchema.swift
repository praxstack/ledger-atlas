import CryptoKit
import Foundation

public struct CanonicalSchemaObject: Equatable, Sendable {
  public let type: String
  public let name: String
  public let tableName: String
  public let ddl: String

  public init(type: String, name: String, tableName: String, ddl: String) {
    self.type = type
    self.name = name
    self.tableName = tableName
    self.ddl = ddl
  }
}

public enum CanonicalLedgerSchema {
  public static let version = 13
  public static let applicationID: Int32 = 0x4C_41_54_31

  /// Exact v10 schema objects. Keep this array byte-for-byte stable: lifecycle authentication
  /// relies on it before applying the sole v10-to-v11 migration.
  public static let legacyV10Objects: [CanonicalSchemaObject] = [
    table(
      "ledger_meta",
      """
      CREATE TABLE ledger_meta(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT
      """),
    table(
      "provenance_reference",
      """
      CREATE TABLE provenance_reference(
        provenance_id TEXT PRIMARY KEY,
        artifact_sha256 TEXT NOT NULL,
        profile_id TEXT NOT NULL,
        adapter_version TEXT NOT NULL,
        container_member TEXT,
        source_table TEXT NOT NULL,
        source_record_key TEXT NOT NULL,
        source_column_ordinal INTEGER,
        source_column_name TEXT,
        CHECK(container_member IS NULL OR instr(container_member, char(0)) = 0),
        CHECK(instr(source_table, char(0)) = 0),
        CHECK(instr(source_record_key, char(0)) = 0),
        CHECK(source_column_name IS NULL OR instr(source_column_name, char(0)) = 0)
      ) STRICT
      """),
    table(
      "economic_event",
      """
      CREATE TABLE economic_event(
        event_id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL,
        event_kind TEXT NOT NULL,
        amount_literal TEXT NOT NULL,
        currency_unit TEXT NOT NULL,
        instant_milliseconds INTEGER NOT NULL,
        local_year INTEGER NOT NULL,
        local_month INTEGER NOT NULL,
        local_day INTEGER NOT NULL,
        local_hour INTEGER NOT NULL,
        local_minute INTEGER NOT NULL,
        local_second INTEGER NOT NULL,
        local_millisecond INTEGER NOT NULL,
        timezone_kind TEXT NOT NULL CHECK(timezone_kind IN ('iana', 'fixed')),
        timezone_value TEXT NOT NULL,
        temporal_precision TEXT NOT NULL,
        resolved_offset_seconds INTEGER NOT NULL,
        source_record_id TEXT NOT NULL,
        provenance_id TEXT NOT NULL REFERENCES provenance_reference(provenance_id)
      ) STRICT
      """),
    table(
      "event_source_binding",
      """
      CREATE TABLE event_source_binding(
        event_id TEXT NOT NULL REFERENCES economic_event(event_id),
        semantic TEXT NOT NULL CHECK(semantic IN ('amount', 'currency', 'occurred_at', 'account', 'kind')),
        provenance_id TEXT NOT NULL REFERENCES provenance_reference(provenance_id),
        declared_type TEXT,
        storage_class TEXT NOT NULL CHECK(storage_class IN ('null', 'integer', 'real', 'blob', 'text')),
        CHECK(declared_type IS NULL OR instr(declared_type, char(0)) = 0),
        PRIMARY KEY(event_id, semantic),
        UNIQUE(event_id, provenance_id),
        UNIQUE(event_id, semantic, provenance_id)
      ) STRICT
      """),
    table(
      "sidecar_reference",
      """
      CREATE TABLE sidecar_reference(
        sidecar_id TEXT NOT NULL,
        event_id TEXT NOT NULL REFERENCES economic_event(event_id),
        provenance_id TEXT NOT NULL REFERENCES provenance_reference(provenance_id),
        format_version INTEGER NOT NULL CHECK(format_version = 1),
        declared_type TEXT,
        storage_class TEXT NOT NULL CHECK(storage_class IN ('null', 'integer', 'real', 'blob', 'text')),
        payload BLOB NOT NULL,
        CHECK(declared_type IS NULL OR instr(declared_type, char(0)) = 0),
        CHECK(provenance_id = sidecar_id),
        PRIMARY KEY(sidecar_id, event_id),
        UNIQUE(event_id, provenance_id),
        UNIQUE(sidecar_id, event_id, provenance_id)
      ) STRICT
      """),
    table(
      "import_receipt",
      """
      CREATE TABLE import_receipt(
        idempotency_key TEXT PRIMARY KEY,
        staging_digest TEXT NOT NULL,
        artifact_sha256 TEXT NOT NULL,
        profile_id TEXT NOT NULL,
        adapter_version TEXT NOT NULL,
        reconciliation_hash TEXT NOT NULL,
        event_set_hash TEXT NOT NULL,
        event_count INTEGER NOT NULL CHECK(event_count >= 0),
        schema_version INTEGER NOT NULL CHECK(schema_version = 8)
      ) STRICT
      """),
    table(
      "receipt_event",
      """
      CREATE TABLE receipt_event(
        idempotency_key TEXT NOT NULL REFERENCES import_receipt(idempotency_key),
        event_id TEXT NOT NULL REFERENCES economic_event(event_id),
        PRIMARY KEY(idempotency_key, event_id)
      ) STRICT
      """),
    table(
      "receipt_binding",
      """
      CREATE TABLE receipt_binding(
        idempotency_key TEXT NOT NULL REFERENCES import_receipt(idempotency_key),
        event_id TEXT NOT NULL,
        semantic TEXT NOT NULL CHECK(semantic IN (char(97,109,111,117,110,116), char(99,117,114,114,101,110,99,121), char(111,99,99,117,114,114,101,100,95,97,116), char(97,99,99,111,117,110,116), char(107,105,110,100))),
        provenance_id TEXT NOT NULL REFERENCES provenance_reference(provenance_id),
        PRIMARY KEY(idempotency_key, event_id, semantic),
        FOREIGN KEY(event_id, semantic, provenance_id) REFERENCES event_source_binding(event_id, semantic, provenance_id)
      ) STRICT
      """),
    table(
      "receipt_sidecar",
      """
      CREATE TABLE receipt_sidecar(
        idempotency_key TEXT NOT NULL REFERENCES import_receipt(idempotency_key),
        sidecar_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        provenance_id TEXT NOT NULL REFERENCES provenance_reference(provenance_id),
        PRIMARY KEY(idempotency_key, sidecar_id, event_id),
        FOREIGN KEY(sidecar_id, event_id, provenance_id) REFERENCES sidecar_reference(sidecar_id, event_id, provenance_id)
      ) STRICT
      """),
    table(
      "receipt_preservation_anchor",
      """
      CREATE TABLE receipt_preservation_anchor(
        anchor_id TEXT PRIMARY KEY,
        idempotency_key TEXT NOT NULL REFERENCES import_receipt(idempotency_key),
        source_subject_id TEXT NOT NULL UNIQUE,
        subject_kind TEXT NOT NULL CHECK(subject_kind IN ('table', 'record')),
        artifact_sha256 TEXT NOT NULL,
        profile_id TEXT NOT NULL,
        adapter_version TEXT NOT NULL,
        container_member TEXT,
        source_table TEXT NOT NULL,
        source_record_key TEXT,
        CHECK(container_member IS NULL OR instr(container_member, char(0)) = 0),
        CHECK(instr(source_table, char(0)) = 0),
        CHECK(source_record_key IS NULL OR instr(source_record_key, char(0)) = 0),
        CHECK((subject_kind = 'table' AND source_record_key IS NULL) OR (subject_kind = 'record' AND source_record_key IS NOT NULL AND length(source_record_key) > 0)),
        UNIQUE(idempotency_key, anchor_id),
        UNIQUE(anchor_id, source_subject_id),
        UNIQUE(idempotency_key, anchor_id, source_subject_id, subject_kind)
      ) STRICT
      """),
    table(
      "receipt_preservation_payload",
      """
      CREATE TABLE receipt_preservation_payload(
        payload_id TEXT PRIMARY KEY,
        idempotency_key TEXT NOT NULL REFERENCES import_receipt(idempotency_key),
        anchor_id TEXT NOT NULL,
        source_subject_id TEXT NOT NULL UNIQUE,
        provenance_id TEXT NOT NULL UNIQUE REFERENCES provenance_reference(provenance_id),
        format_version INTEGER NOT NULL CHECK(format_version = 1),
        declared_type TEXT,
        storage_class TEXT NOT NULL CHECK(storage_class IN ('null', 'integer', 'real', 'blob', 'text')),
        payload BLOB NOT NULL,
        CHECK(declared_type IS NULL OR instr(declared_type, char(0)) = 0),
        CHECK(provenance_id = source_subject_id),
        UNIQUE(idempotency_key, anchor_id, payload_id, source_subject_id),
        FOREIGN KEY(idempotency_key, anchor_id) REFERENCES receipt_preservation_anchor(idempotency_key, anchor_id)
      ) STRICT
      """),
    table(
      "receipt_preservation_membership",
      """
      CREATE TABLE receipt_preservation_membership(
        idempotency_key TEXT NOT NULL REFERENCES import_receipt(idempotency_key),
        source_subject_id TEXT NOT NULL,
        subject_kind TEXT NOT NULL CHECK(subject_kind IN ('table', 'record', 'field')),
        anchor_id TEXT NOT NULL,
        anchor_subject_id TEXT NOT NULL,
        anchor_subject_kind TEXT NOT NULL CHECK(anchor_subject_kind IN ('table', 'record')),
        payload_id TEXT,
        PRIMARY KEY(idempotency_key, source_subject_id),
        FOREIGN KEY(idempotency_key, anchor_id, anchor_subject_id, anchor_subject_kind) REFERENCES receipt_preservation_anchor(idempotency_key, anchor_id, source_subject_id, subject_kind),
        FOREIGN KEY(idempotency_key, anchor_id, payload_id, source_subject_id) REFERENCES receipt_preservation_payload(idempotency_key, anchor_id, payload_id, source_subject_id),
        CHECK((subject_kind IN ('table', 'record') AND payload_id IS NULL AND source_subject_id = anchor_subject_id AND subject_kind = anchor_subject_kind) OR (subject_kind = 'field' AND payload_id IS NOT NULL AND source_subject_id != anchor_subject_id AND anchor_subject_kind = 'record'))
      ) STRICT
      """),
    table(
      "ledger_origin",
      """
      CREATE TABLE ledger_origin(
        origin_id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        provenance_id TEXT REFERENCES provenance_reference(provenance_id)
      ) STRICT
      """),
    table(
      "ledger_account",
      """
      CREATE TABLE ledger_account(
        account_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        currency_unit TEXT NOT NULL,
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))
      ) STRICT
      """),
    table(
      "ledger_category",
      """
      CREATE TABLE ledger_category(
        category_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('income', 'expense', 'neutral')),
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))
      ) STRICT
      """),
    table(
      "ledger_transaction",
      """
      CREATE TABLE ledger_transaction(
        transaction_id TEXT PRIMARY KEY,
        current_revision_id TEXT NOT NULL,
        FOREIGN KEY(transaction_id, current_revision_id)
          REFERENCES ledger_transaction_revision(transaction_id, revision_id)
          DEFERRABLE INITIALLY DEFERRED
      ) STRICT
      """),
    table(
      "ledger_transaction_revision",
      """
      CREATE TABLE ledger_transaction_revision(
        revision_id TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL REFERENCES ledger_transaction(transaction_id),
        revision INTEGER NOT NULL CHECK(revision > 0),
        predecessor_id TEXT REFERENCES ledger_transaction_revision(revision_id),
        category_id TEXT REFERENCES ledger_category(category_id),
        kind TEXT NOT NULL CHECK(kind IN ('income', 'expense', 'transfer', 'adjustment')),
        instant_milliseconds INTEGER NOT NULL,
        local_year INTEGER NOT NULL,
        local_month INTEGER NOT NULL,
        local_day INTEGER NOT NULL,
        local_hour INTEGER NOT NULL,
        local_minute INTEGER NOT NULL,
        local_second INTEGER NOT NULL,
        local_millisecond INTEGER NOT NULL,
        timezone_kind TEXT NOT NULL CHECK(timezone_kind IN ('iana', 'fixed')),
        timezone_value TEXT NOT NULL,
        temporal_precision TEXT NOT NULL CHECK(temporal_precision IN ('day', 'minute', 'second', 'millisecond')),
        resolved_offset_seconds INTEGER NOT NULL,
        note TEXT,
        rounding_policy TEXT CHECK(rounding_policy IN ('towardZero', 'awayFromZero', 'floor', 'ceiling', 'halfUp', 'halfEven')),
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned')),
        created_at_milliseconds INTEGER NOT NULL,
        UNIQUE(transaction_id, revision),
        UNIQUE(transaction_id, revision_id)
      ) STRICT
      """),
    table(
      "ledger_transaction_effect",
      """
      CREATE TABLE ledger_transaction_effect(
        revision_id TEXT NOT NULL REFERENCES ledger_transaction_revision(revision_id),
        account_id TEXT NOT NULL REFERENCES ledger_account(account_id),
        direction TEXT NOT NULL CHECK(direction IN ('increase', 'decrease')),
        amount_literal TEXT NOT NULL,
        currency_unit TEXT NOT NULL,
        PRIMARY KEY(revision_id, account_id)
      ) STRICT
      """),
    table(
      "ledger_transaction_source_literal",
      """
      CREATE TABLE ledger_transaction_source_literal(
        revision_id TEXT NOT NULL REFERENCES ledger_transaction_revision(revision_id),
        ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
        field TEXT NOT NULL,
        literal TEXT NOT NULL,
        provenance_id TEXT REFERENCES provenance_reference(provenance_id),
        PRIMARY KEY(revision_id, ordinal),
        UNIQUE(revision_id, field, provenance_id)
      ) STRICT
      """),
    table(
      "ledger_transaction_link",
      """
      CREATE TABLE ledger_transaction_link(
        link_id TEXT PRIMARY KEY,
        from_transaction_id TEXT NOT NULL REFERENCES ledger_transaction(transaction_id),
        to_transaction_id TEXT NOT NULL REFERENCES ledger_transaction(transaction_id),
        kind TEXT NOT NULL CHECK(kind IN ('split', 'recurring', 'installment', 'related')),
        CHECK(from_transaction_id != to_transaction_id),
        UNIQUE(from_transaction_id, to_transaction_id, kind)
      ) STRICT
      """),
    immutableUpdateTrigger("ledger_transaction_revision"),
    immutableDeleteTrigger("ledger_transaction_revision"),
    immutableUpdateTrigger("ledger_transaction_effect"),
    immutableDeleteTrigger("ledger_transaction_effect"),
    immutableUpdateTrigger("ledger_transaction_source_literal"),
    immutableDeleteTrigger("ledger_transaction_source_literal"),
    immutableUpdateTrigger("ledger_transaction_link"),
    immutableDeleteTrigger("ledger_transaction_link"),
    table(
      "ledger_recurrence_rule",
      """
      CREATE TABLE ledger_recurrence_rule(
        rule_id TEXT PRIMARY KEY,
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        account_id TEXT NOT NULL REFERENCES ledger_account(account_id),
        category_id TEXT REFERENCES ledger_category(category_id),
        kind TEXT NOT NULL CHECK(kind IN ('income', 'expense')),
        amount_literal TEXT NOT NULL,
        currency_unit TEXT NOT NULL,
        frequency TEXT NOT NULL CHECK(frequency IN ('daily', 'weekly', 'monthly', 'yearly')),
        interval INTEGER NOT NULL CHECK(interval > 0),
        day_of_month INTEGER CHECK(day_of_month IS NULL OR (day_of_month >= 1 AND day_of_month <= 31)),
        timezone_kind TEXT NOT NULL CHECK(timezone_kind IN ('iana', 'fixed')),
        timezone_value TEXT NOT NULL,
        start_year INTEGER NOT NULL,
        start_month INTEGER NOT NULL,
        start_day INTEGER NOT NULL,
        until_year INTEGER,
        until_month INTEGER,
        until_day INTEGER,
        paused INTEGER NOT NULL CHECK(paused IN (0, 1)),
        skipped TEXT NOT NULL,
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))
      ) STRICT
      """),
    table(
      "ledger_budget",
      """
      CREATE TABLE ledger_budget(
        budget_id TEXT PRIMARY KEY,
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        name TEXT NOT NULL,
        category_id TEXT NOT NULL REFERENCES ledger_category(category_id),
        currency_unit TEXT NOT NULL,
        amount_literal TEXT NOT NULL,
        period TEXT NOT NULL CHECK(period IN ('monthly', 'yearly')),
        rollover INTEGER NOT NULL CHECK(rollover IN (0, 1)),
        start_year INTEGER NOT NULL,
        start_month INTEGER NOT NULL,
        start_day INTEGER NOT NULL,
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))
      ) STRICT
      """),
    table(
      "ledger_installment_plan",
      """
      CREATE TABLE ledger_installment_plan(
        plan_id TEXT PRIMARY KEY,
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        account_id TEXT NOT NULL REFERENCES ledger_account(account_id),
        category_id TEXT REFERENCES ledger_category(category_id),
        principal_literal TEXT NOT NULL,
        currency_unit TEXT NOT NULL,
        occurrence_count INTEGER NOT NULL CHECK(occurrence_count > 0),
        completed_count INTEGER NOT NULL CHECK(completed_count >= 0),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'cancelled', 'completed'))
      ) STRICT
      """),
  ].sorted { ($0.type, $0.name) < ($1.type, $1.name) }

  private static let v11Objects: [CanonicalSchemaObject] = [
    table(
      "ledger_receipt_trust_anchor",
      """
      CREATE TABLE ledger_receipt_trust_anchor(
        idempotency_key TEXT PRIMARY KEY REFERENCES import_receipt(idempotency_key),
        algorithm TEXT NOT NULL CHECK(algorithm = 'hmac-sha256'),
        signature TEXT NOT NULL CHECK(
          length(signature) = 64 AND signature NOT GLOB '*[^0-9a-f]*'
        )
      ) STRICT
      """),
    table(
      "ledger_category_tree",
      """
      CREATE TABLE ledger_category_tree(
        category_id TEXT PRIMARY KEY REFERENCES ledger_category(category_id),
        parent_category_id TEXT REFERENCES ledger_category(category_id),
        display_order INTEGER NOT NULL CHECK(display_order >= 0),
        hidden INTEGER NOT NULL CHECK(hidden IN (0, 1)),
        CHECK(parent_category_id IS NULL OR parent_category_id != category_id)
      ) STRICT
      """),
    table(
      "ledger_account_group",
      """
      CREATE TABLE ledger_account_group(
        group_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        display_order INTEGER NOT NULL CHECK(display_order >= 0),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))
      ) STRICT
      """),
    table(
      "ledger_account_preferences",
      """
      CREATE TABLE ledger_account_preferences(
        account_id TEXT PRIMARY KEY REFERENCES ledger_account(account_id),
        group_id TEXT REFERENCES ledger_account_group(group_id),
        display_order INTEGER NOT NULL CHECK(display_order >= 0),
        hidden INTEGER NOT NULL CHECK(hidden IN (0, 1)),
        include_in_totals INTEGER NOT NULL CHECK(include_in_totals IN (0, 1)),
        variant TEXT NOT NULL
      ) STRICT
      """),
  ]

  /// v12: tags, transaction templates and standalone memos (T1), plus pairs of imported
  /// transfer legs (economic_event_transfer). Additive only.
  ///
  /// Revision tag links are immutable like every other part of a revision: a correction writes
  /// a new revision with its own links. Template tag links are replaced when a template is
  /// edited. Unique active tag names compare case- and composition-insensitively, which SQLite
  /// cannot express, so the store and the health check enforce that rule.
  private static let v12Objects: [CanonicalSchemaObject] = [
    table(
      "ledger_tag",
      """
      CREATE TABLE ledger_tag(
        tag_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))
      ) STRICT
      """),
    table(
      "ledger_revision_tag",
      """
      CREATE TABLE ledger_revision_tag(
        revision_id TEXT NOT NULL REFERENCES ledger_transaction_revision(revision_id),
        tag_id TEXT NOT NULL REFERENCES ledger_tag(tag_id),
        PRIMARY KEY(revision_id, tag_id)
      ) STRICT
      """),
    immutableUpdateTrigger("ledger_revision_tag"),
    immutableDeleteTrigger("ledger_revision_tag"),
    table(
      "ledger_transaction_template",
      """
      CREATE TABLE ledger_transaction_template(
        template_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('income', 'expense', 'transfer')),
        category_id TEXT REFERENCES ledger_category(category_id),
        amount_literal TEXT NOT NULL,
        currency_unit TEXT NOT NULL,
        note TEXT,
        account_id TEXT NOT NULL REFERENCES ledger_account(account_id),
        counter_account_id TEXT REFERENCES ledger_account(account_id),
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned')),
        CHECK((kind = 'transfer') = (counter_account_id IS NOT NULL)),
        CHECK(kind != 'transfer' OR category_id IS NULL),
        CHECK(counter_account_id IS NULL OR counter_account_id != account_id)
      ) STRICT
      """),
    table(
      "ledger_template_tag",
      """
      CREATE TABLE ledger_template_tag(
        template_id TEXT NOT NULL REFERENCES ledger_transaction_template(template_id),
        tag_id TEXT NOT NULL REFERENCES ledger_tag(tag_id),
        PRIMARY KEY(template_id, tag_id)
      ) STRICT
      """),
    table(
      "ledger_memo",
      """
      CREATE TABLE ledger_memo(
        memo_id TEXT PRIMARY KEY,
        body TEXT NOT NULL,
        local_year INTEGER NOT NULL,
        local_month INTEGER NOT NULL CHECK(local_month BETWEEN 1 AND 12),
        local_day INTEGER NOT NULL CHECK(local_day BETWEEN 1 AND 31),
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))
      ) STRICT
      """),
    // Pairs the two imported legs of one transfer so they can show as a single transfer.
    table(
      "economic_event_transfer",
      """
      CREATE TABLE economic_event_transfer(
        transfer_id TEXT PRIMARY KEY,
        debit_event_id TEXT NOT NULL UNIQUE REFERENCES economic_event(event_id),
        credit_event_id TEXT NOT NULL UNIQUE REFERENCES economic_event(event_id),
        CHECK(debit_event_id <> credit_event_id)
      ) STRICT
      """),
  ]

  /// v13: receipt images kept inside the ledger, so a backup carries them exactly. Additive
  /// only. A receipt may be unlinked (transaction_id NULL) or point at a ledger transaction,
  /// an imported event or an imported transfer; the health check validates that, since one
  /// foreign key cannot cover all three. sha256 and byte_count must match the bytes, which the
  /// health check verifies when a ledger is opened. Only the link and the lifecycle can change,
  /// and tombstoned is terminal. A tombstoned receipt keeps its bytes so a restore is exact.
  /// No file name and no OCR text are stored.
  private static let v13Objects: [CanonicalSchemaObject] = [
    table(
      "ledger_receipt_attachment",
      """
      CREATE TABLE ledger_receipt_attachment(
        attachment_id TEXT PRIMARY KEY CHECK(length(attachment_id) = 64),
        transaction_id TEXT CHECK(transaction_id IS NULL OR length(transaction_id) = 64),
        sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
        byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 26214400),
        media_type TEXT NOT NULL CHECK(media_type IN ('image/jpeg', 'image/png', 'image/heic', 'application/pdf')),
        bytes BLOB NOT NULL,
        origin_id TEXT NOT NULL REFERENCES ledger_origin(origin_id),
        created_at_milliseconds INTEGER NOT NULL,
        lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active', 'tombstoned'))
      ) STRICT
      """),
    // The image and its digest never change once stored; only the link and lifecycle do.
    trigger(
      "ledger_receipt_attachment_content_immutable", on: "ledger_receipt_attachment",
      """
      CREATE TRIGGER ledger_receipt_attachment_content_immutable
      BEFORE UPDATE OF attachment_id, sha256, byte_count, media_type, bytes, origin_id, created_at_milliseconds ON ledger_receipt_attachment
      BEGIN
        SELECT RAISE(ABORT, 'immutable receipt content');
      END
      """),
    // Tombstoned is terminal: a removed receipt never changes again.
    trigger(
      "ledger_receipt_attachment_tombstone_terminal", on: "ledger_receipt_attachment",
      """
      CREATE TRIGGER ledger_receipt_attachment_tombstone_terminal
      BEFORE UPDATE ON ledger_receipt_attachment
      WHEN OLD.lifecycle = 'tombstoned'
      BEGIN
        SELECT RAISE(ABORT, 'tombstoned receipt');
      END
      """),
    immutableDeleteTrigger("ledger_receipt_attachment"),
  ]

  /// Exact v12 schema objects, frozen when v13 was added. Do not derive new objects into this.
  public static let legacyV12Objects = (legacyV11Objects + v12Objects).sorted {
    ($0.type, $0.name) < ($1.type, $1.name)
  }

  /// Exact v11 schema objects, frozen when v12 was added. Do not derive new objects into this.
  public static let legacyV11Objects = (legacyV10Objects + v11Objects).sorted {
    ($0.type, $0.name) < ($1.type, $1.name)
  }

  public static let expectedObjects = (legacyV12Objects + v13Objects).sorted {
    ($0.type, $0.name) < ($1.type, $1.name)
  }

  public static let creationStatements = expectedObjects.map(\.ddl)

  /// Exact v8 import-era schema objects, retained for authenticated additive migration.
  public static let legacyV8Objects = legacyV10Objects.filter {
    !$0.name.hasPrefix("ledger_") || $0.name == "ledger_meta"
  }

  /// The released v8 object names are frozen alongside the fingerprint. They are not derived
  /// from the evolving application schema during legacy authentication.
  public static let legacyV8TableNames = [
    "economic_event", "event_source_binding", "import_receipt", "ledger_meta",
    "provenance_reference", "receipt_binding", "receipt_event", "receipt_preservation_anchor",
    "receipt_preservation_membership", "receipt_preservation_payload", "receipt_sidecar",
    "sidecar_reference",
  ]

  /// Released v8 compatibility identity. Do not derive this from current DDL: v8 is an
  /// immutable import contract, not a moving view of the latest schema.
  public static let legacyV8Fingerprint =
    "f5526a4621eeb0e780851c3b50444d0c387f48ea953f1c1860da3204c8db91dc"

  public static let legacyV10Fingerprint =
    "aca9d078dd357cd64a6fe209e04fb7e3ac724525cf15b8c313e0b8177d2b6926"

  private static let v10TableNames: Set<String> = [
    "ledger_recurrence_rule", "ledger_budget", "ledger_installment_plan",
  ]

  /// Statements for a committer to apply inside its own atomic v8-to-v9 migration.
  /// This deliberately contains only additive application objects; metadata updates stay with the
  /// committer that owns the migration transaction.
  public static let v8ToV9MigrationStatements =
    legacyV10Objects
    .filter {
      $0.name.hasPrefix("ledger_") && $0.name != "ledger_meta" && !v10TableNames.contains($0.name)
    }
    .map(\.ddl)

  public static let v9ToV10MigrationStatements =
    legacyV10Objects.filter { v10TableNames.contains($0.name) }.map(\.ddl)

  public static let v10ToV11MigrationStatements = v11Objects.map(\.ddl)

  /// Tables before the triggers that guard them.
  public static let v11ToV12MigrationStatements =
    v12Objects.filter { $0.type == "table" }.map(\.ddl)
    + v12Objects.filter { $0.type != "table" }.map(\.ddl)

  /// Tables before the triggers that guard them.
  public static let v12ToV13MigrationStatements =
    v13Objects.filter { $0.type == "table" }.map(\.ddl)
    + v13Objects.filter { $0.type != "table" }.map(\.ddl)

  public static func additiveMigrationStatements(fromVersion: Int) -> [String]? {
    switch fromVersion {
    case 8: v8ToV9MigrationStatements
    case 9: v9ToV10MigrationStatements
    case 10: v10ToV11MigrationStatements
    case 11: v11ToV12MigrationStatements
    case 12: v12ToV13MigrationStatements
    case 13: []
    default: nil
    }
  }

  public static let fingerprint = schemaFingerprint(for: expectedObjects)

  /// One released canonical schema: its version, fingerprint, and exact objects.
  public struct SchemaRelease: Equatable, Sendable {
    public let version: Int
    public let fingerprint: String
    public let objects: [CanonicalSchemaObject]
    /// False for releases before v11. Those have no receipt trust anchors, so an imported
    /// graph in them cannot be re-authenticated after the file has been writable.
    public let authenticatesImportedEvents: Bool
    /// The semantic checksum queries of this release. A portable package records its ledger's
    /// checksum at export, so restoring an older package recomputes it with these.
    public let checksumQueries: [String]
  }

  /// One additive step from a released schema to the next. Statements run inside the
  /// lifecycle's migration transaction; the lifecycle updates `ledger_meta` itself.
  public struct LifecycleUpgradeStep: Sendable {
    public let from: SchemaRelease
    public let to: SchemaRelease
    public let statements: [String]
  }

  public static let currentRelease = SchemaRelease(
    version: version, fingerprint: fingerprint, objects: expectedObjects,
    authenticatesImportedEvents: true, checksumQueries: checksumQueries)

  public static let legacyV10Release = SchemaRelease(
    version: 10, fingerprint: legacyV10Fingerprint, objects: legacyV10Objects,
    authenticatesImportedEvents: false, checksumQueries: legacyV10ChecksumQueries)

  /// Released v11 identity. A literal, not derived, so a later schema edit cannot move it.
  public static let legacyV11Fingerprint =
    "513702f73c663ad72e0af52304e9f4eabf3ba31aafae259abdbd3d0f74d73fc4"

  /// Released v11 checksum queries, frozen like its fingerprint.
  public static let legacyV11ChecksumQueries =
    legacyV10ChecksumQueries + [
      "SELECT idempotency_key, algorithm, signature FROM ledger_receipt_trust_anchor ORDER BY idempotency_key",
      "SELECT category_id, parent_category_id, display_order, hidden FROM ledger_category_tree ORDER BY category_id",
      "SELECT group_id, name, display_order, lifecycle FROM ledger_account_group ORDER BY group_id",
      "SELECT account_id, group_id, display_order, hidden, include_in_totals, variant FROM ledger_account_preferences ORDER BY account_id",
    ]

  public static let legacyV11Release = SchemaRelease(
    version: 11, fingerprint: legacyV11Fingerprint, objects: legacyV11Objects,
    authenticatesImportedEvents: true, checksumQueries: legacyV11ChecksumQueries)

  /// Released v12 identity. A literal, not derived, so a later schema edit cannot move it.
  public static let legacyV12Fingerprint =
    "c6b67526e3c6d26c430e9dbfbdcdb39bd0517172a0a50369e86ea94eb13b5355"

  public static let legacyV12Release = SchemaRelease(
    version: 12, fingerprint: legacyV12Fingerprint, objects: legacyV12Objects,
    authenticatesImportedEvents: true)

  /// The upgrade chain the ledger lifecycle can apply, oldest first. Each step's `to` is the
  /// next step's `from`, and the last step ends at `currentRelease`.
  ///
  /// To add a schema version N+1: freeze today's objects, fingerprint and checksum queries as a
  /// `vN` release (stop deriving them from the evolving schema), point the last step's `to` at
  /// it, and append a step from it to `currentRelease` with the new objects' DDL. Portable
  /// packages of imported ledgers restore through this chain, so never drop a release from v12 on.  Lifecycle validates legacy
  /// files without the receipt trust key, so check that the frozen release's health checks
  /// still pass that way.
  public static let lifecycleUpgradeSteps: [LifecycleUpgradeStep] = [
    LifecycleUpgradeStep(
      from: legacyV10Release, to: legacyV11Release, statements: v10ToV11MigrationStatements),
    LifecycleUpgradeStep(
      from: legacyV11Release, to: legacyV12Release, statements: v11ToV12MigrationStatements),
    LifecycleUpgradeStep(
      from: legacyV12Release, to: currentRelease, statements: v12ToV13MigrationStatements),
  ]

  /// The released schema with this exact version and fingerprint that the lifecycle can upgrade,
  /// or nil when it is unknown or already current.
  public static func lifecycleLegacyRelease(version: Int, fingerprint: String) -> SchemaRelease? {
    lifecycleUpgradeSteps.first {
      $0.from.version == version && $0.from.fingerprint == fingerprint
    }?.from
  }

  /// The steps that upgrade `release` to the current schema, in order, or nil when no unbroken
  /// chain reaches `currentRelease`.
  public static func lifecycleUpgradePath(from release: SchemaRelease) -> [LifecycleUpgradeStep]? {
    var path: [LifecycleUpgradeStep] = []
    var at = release
    while at != currentRelease {
      guard let step = lifecycleUpgradeSteps.first(where: { $0.from == at }),
        step.to.version > at.version, path.count < lifecycleUpgradeSteps.count
      else { return nil }
      path.append(step)
      at = step.to
    }
    return path.isEmpty ? nil : path
  }

  public static func schemaFingerprint(for objects: [CanonicalSchemaObject]) -> String {
    var hasher = SHA256()
    update(&hasher, Data("ledger-atlas/canonical-schema/v1".utf8))
    for object in objects {
      for component in [object.type, object.name, object.tableName, normalizedDDL(object.ddl)] {
        update(&hasher, Data(component.utf8))
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static let legacyV10ChecksumQueries: [String] = [
    "SELECT key, value FROM ledger_meta ORDER BY key",
    "SELECT event_id, account_id, event_kind, amount_literal, currency_unit, instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute, local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision, resolved_offset_seconds, source_record_id, provenance_id FROM economic_event ORDER BY event_id",
    "SELECT event_id, semantic, provenance_id, declared_type, storage_class FROM event_source_binding ORDER BY event_id, semantic",
    "SELECT provenance_id, artifact_sha256, profile_id, adapter_version, container_member, source_table, source_record_key, source_column_ordinal, source_column_name FROM provenance_reference ORDER BY provenance_id",
    "SELECT sidecar_id, event_id, provenance_id, format_version, declared_type, storage_class, payload FROM sidecar_reference ORDER BY sidecar_id, event_id",
    "SELECT idempotency_key, staging_digest, artifact_sha256, profile_id, adapter_version, reconciliation_hash, event_set_hash, event_count, schema_version FROM import_receipt ORDER BY idempotency_key",
    "SELECT idempotency_key, event_id FROM receipt_event ORDER BY idempotency_key, event_id",
    "SELECT idempotency_key, event_id, semantic, provenance_id FROM receipt_binding ORDER BY idempotency_key, event_id, semantic",
    "SELECT idempotency_key, sidecar_id, event_id, provenance_id FROM receipt_sidecar ORDER BY idempotency_key, sidecar_id, event_id",
    "SELECT anchor_id, idempotency_key, source_subject_id, subject_kind, artifact_sha256, profile_id, adapter_version, container_member, source_table, source_record_key FROM receipt_preservation_anchor ORDER BY anchor_id",
    "SELECT payload_id, idempotency_key, anchor_id, source_subject_id, provenance_id, format_version, declared_type, storage_class, payload FROM receipt_preservation_payload ORDER BY payload_id",
    "SELECT idempotency_key, source_subject_id, subject_kind, anchor_id, anchor_subject_id, anchor_subject_kind, payload_id FROM receipt_preservation_membership ORDER BY idempotency_key, source_subject_id",
    "SELECT origin_id, label, provenance_id FROM ledger_origin ORDER BY origin_id",
    "SELECT account_id, name, currency_unit, origin_id, lifecycle FROM ledger_account ORDER BY account_id",
    "SELECT category_id, name, kind, origin_id, lifecycle FROM ledger_category ORDER BY category_id",
    "SELECT transaction_id, current_revision_id FROM ledger_transaction ORDER BY transaction_id",
    "SELECT revision_id, transaction_id, revision, predecessor_id, category_id, kind, instant_milliseconds, local_year, local_month, local_day, local_hour, local_minute, local_second, local_millisecond, timezone_kind, timezone_value, temporal_precision, resolved_offset_seconds, note, rounding_policy, origin_id, lifecycle, created_at_milliseconds FROM ledger_transaction_revision ORDER BY revision_id",
    "SELECT revision_id, account_id, direction, amount_literal, currency_unit FROM ledger_transaction_effect ORDER BY revision_id, account_id",
    "SELECT revision_id, ordinal, field, literal, provenance_id FROM ledger_transaction_source_literal ORDER BY revision_id, ordinal",
    "SELECT link_id, from_transaction_id, to_transaction_id, kind FROM ledger_transaction_link ORDER BY link_id",
    "SELECT rule_id, origin_id, account_id, category_id, kind, amount_literal, currency_unit, frequency, interval, day_of_month, timezone_kind, timezone_value, start_year, start_month, start_day, until_year, until_month, until_day, paused, skipped, lifecycle FROM ledger_recurrence_rule ORDER BY rule_id",
    "SELECT budget_id, origin_id, name, category_id, currency_unit, amount_literal, period, rollover, start_year, start_month, start_day, lifecycle FROM ledger_budget ORDER BY budget_id",
    "SELECT plan_id, origin_id, account_id, category_id, principal_literal, currency_unit, occurrence_count, completed_count, lifecycle FROM ledger_installment_plan ORDER BY plan_id",
  ]

  public static let checksumQueries =
    legacyV10ChecksumQueries + [
      "SELECT idempotency_key, algorithm, signature FROM ledger_receipt_trust_anchor ORDER BY idempotency_key",
      "SELECT category_id, parent_category_id, display_order, hidden FROM ledger_category_tree ORDER BY category_id",
      "SELECT group_id, name, display_order, lifecycle FROM ledger_account_group ORDER BY group_id",
      "SELECT account_id, group_id, display_order, hidden, include_in_totals, variant FROM ledger_account_preferences ORDER BY account_id",
      "SELECT tag_id, name, origin_id, lifecycle FROM ledger_tag ORDER BY tag_id",
      "SELECT revision_id, tag_id FROM ledger_revision_tag ORDER BY revision_id, tag_id",
      "SELECT template_id, name, kind, category_id, amount_literal, currency_unit, note, account_id, counter_account_id, origin_id, lifecycle FROM ledger_transaction_template ORDER BY template_id",
      "SELECT template_id, tag_id FROM ledger_template_tag ORDER BY template_id, tag_id",
      "SELECT memo_id, body, local_year, local_month, local_day, origin_id, lifecycle FROM ledger_memo ORDER BY memo_id",
      "SELECT transfer_id, debit_event_id, credit_event_id FROM economic_event_transfer ORDER BY transfer_id",
      // The image is covered by its sha256, which the health check verifies on open, so the
      // checksum stays fast for large ledgers.
      "SELECT attachment_id, transaction_id, sha256, byte_count, media_type, origin_id, created_at_milliseconds, lifecycle FROM ledger_receipt_attachment ORDER BY attachment_id",
    ]

  public static func normalizedDDL(_ ddl: String) -> String {
    ddl.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func table(_ name: String, _ ddl: String) -> CanonicalSchemaObject {
    CanonicalSchemaObject(
      type: "table", name: name, tableName: name, ddl: normalizedDDL(ddl))
  }

  private static func immutableUpdateTrigger(_ tableName: String) -> CanonicalSchemaObject {
    trigger(
      "\(tableName)_immutable_update", on: tableName,
      """
      CREATE TRIGGER \(tableName)_immutable_update
      BEFORE UPDATE ON \(tableName)
      BEGIN
        SELECT RAISE(ABORT, 'immutable ledger history');
      END
      """)
  }

  private static func immutableDeleteTrigger(_ tableName: String) -> CanonicalSchemaObject {
    trigger(
      "\(tableName)_immutable_delete", on: tableName,
      """
      CREATE TRIGGER \(tableName)_immutable_delete
      BEFORE DELETE ON \(tableName)
      BEGIN
        SELECT RAISE(ABORT, 'immutable ledger history');
      END
      """)
  }

  private static func trigger(_ name: String, on tableName: String, _ ddl: String)
    -> CanonicalSchemaObject
  {
    CanonicalSchemaObject(
      type: "trigger", name: name, tableName: tableName, ddl: normalizedDDL(ddl))
  }

  private static func update(_ hasher: inout SHA256, _ data: Data) {
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: data)
  }
}
