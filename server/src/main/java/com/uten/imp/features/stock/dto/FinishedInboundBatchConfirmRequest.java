package com.uten.imp.features.stock.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.util.List;
import java.util.UUID;

/** Atomic full acceptance of several production-generated FINISHED_IN drafts. */
@Getter
@Setter
public class FinishedInboundBatchConfirmRequest {

    @NotBlank
    @Size(min = 8, max = 128)
    @Pattern(regexp = "[A-Za-z0-9._:-]+")
    private String idempotencyKey;

    @NotNull
    @Size(min = 1, max = 50)
    private List<@NotNull UUID> documentIds;
}
