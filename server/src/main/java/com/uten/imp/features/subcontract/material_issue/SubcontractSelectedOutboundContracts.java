package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;
import java.util.UUID;

public final class SubcontractSelectedOutboundContracts {
    private SubcontractSelectedOutboundContracts() {}
    public record Review(MaterialIssueDetail document, String fingerprint) {}
    public record Request(@NotBlank String idempotencyKey, @NotBlank String fingerprint,
                          @NotEmpty @Size(max=com.uten.imp.common.validation.RequestLimits.DOCUMENT_LINES) List<@NotNull UUID> itemIds,
                          @NotNull @Valid MaterialIssueSaveRequest document) {}
    public record Result(UUID sourceIssueId, UUID executionIssueId, String billNo, List<UUID> itemIds, short status) {}
    public record Receipt(Result result) {}
}
