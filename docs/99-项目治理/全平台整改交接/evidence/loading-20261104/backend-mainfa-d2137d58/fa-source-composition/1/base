package com.uten.imp.application.port;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import java.util.List;
import java.util.UUID;

/** Family-owned reversal and explicit draft input snapshots; never client-authored clones. */
public interface DocumentUnapprovalPort {
    String family();
    String permission();
    DocNumberPrefix numberPrefix(UUID originalId);
    TableSnapshot header();
    TableSnapshot lines();
    Object detail(UUID id);
    void reverse(UUID id);
    /** Read-only domain preflight, shared with the final reversal's existing guards. */
    default Eligibility eligibility(UUID id) {
        return Eligibility.blocked("PREFLIGHT_UNAVAILABLE", "当前无法核对反审条件，请重新读取后再操作", null);
    }
    default void requireSupported(UUID id) { }
    default void afterDraftCreated(UUID originalId, UUID draftId) { }
    default List<SourceSnapshot> sources() { return List.of(); }
    default java.util.Map<String,String> generatedLineInputs() { return java.util.Map.of(); }

    record Reason(String code, String message) {
        public Reason {
            if (code == null || !code.matches("[A-Z][A-Z0-9_]{0,63}") || message == null || message.isBlank())
                throw new IllegalArgumentException("Invalid unapproval reason");
        }
    }
    /** A domain may include a reference only after its usual read scope permits that document. */
    record RelatedDocument(String family, UUID id, String billNo) { }
    record Eligibility(boolean eligible, List<Reason> reasons, List<RelatedDocument> relatedDocuments,
                       String factsSnapshot) {
        public Eligibility {
            reasons = List.copyOf(reasons); relatedDocuments = List.copyOf(relatedDocuments);
            if (eligible && !reasons.isEmpty()) throw new IllegalArgumentException("Allowed action cannot have blocking reasons");
            if (eligible && (factsSnapshot==null || !factsSnapshot.matches("[a-f0-9]{64}")))
                throw new IllegalArgumentException("Allowed action requires an exact facts snapshot");
            if (!eligible && reasons.isEmpty()) throw new IllegalArgumentException("Blocked action needs a reason");
        }
        public static Eligibility ready(String factsSnapshot) {
            return new Eligibility(true, List.of(), List.of(), factsSnapshot);
        }
        public static Eligibility blocked(String code, String message, String factsSnapshot) {
            return new Eligibility(false, List.of(new Reason(code, message)), List.of(), factsSnapshot);
        }
    }

    /** Exact reviewed columns. Omitted posting, approval and cumulative fields use draft defaults. */
    record TableSnapshot(String table, String parentColumn, List<String> inputs,
                         boolean softDeleted, boolean lineBillNumber) {
        public TableSnapshot {
            if (!table.matches("[a-z_]+") || (parentColumn != null && !parentColumn.matches("[a-z_]+"))
                    || inputs.stream().anyMatch(value -> !value.matches("[a-z_]+")))
                throw new IllegalArgumentException("Invalid document snapshot identifiers");
            inputs = List.copyOf(inputs);
        }
    }

    /** A line's unchanged source identities and exact allocated quantities, remapped to its successor. */
    record SourceSnapshot(String table, String lineColumn, List<String> inputs) {
        public SourceSnapshot {
            if (!table.matches("[a-z_]+") || !lineColumn.matches("[a-z_]+")
                    || inputs.stream().anyMatch(value -> !value.matches("[a-z_]+")))
                throw new IllegalArgumentException("Invalid document source identifiers");
            inputs = List.copyOf(inputs);
        }
    }
}
