package com.uten.imp.application.port;
import java.util.UUID;

/** Pure original-custody checks after the subcontract document's read and reverse scopes pass. */
public interface SubcontractMaterialReversalValuePort {
    String requireIssueReversible(UUID issueId);
    String requireReturnReversible(UUID returnId);
}
