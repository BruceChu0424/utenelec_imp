package com.uten.imp.responsibility.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.util.Set;
import java.util.UUID;

/** Atomic manual handover command. The caller must explicitly choose 1-8 supported scopes. */
public record DataHandoverRequest(
        @NotNull UUID requestId,
        @NotNull UUID sourceEmployeeId,
        @NotNull UUID targetEmployeeId,
        @NotEmpty @Size(max = 8) Set<@NotBlank String> scopes,
        @NotBlank @Size(max = 2000) String reason,
        @NotNull LocalDate effectiveDate
) {
}
