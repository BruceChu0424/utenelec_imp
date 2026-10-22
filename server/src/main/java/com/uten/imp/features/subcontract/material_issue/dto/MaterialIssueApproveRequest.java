package com.uten.imp.features.subcontract.material_issue.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;
import java.util.UUID;

public record MaterialIssueApproveRequest(
        @Size(min = 1, max = RequestLimits.DOCUMENT_LINES) List<@NotNull UUID> itemIds) { }
