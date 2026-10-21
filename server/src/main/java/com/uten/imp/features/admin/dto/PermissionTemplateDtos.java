package com.uten.imp.features.admin.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import java.util.UUID;
import static com.uten.imp.features.admin.dto.PermissionTransferDtos.StrictFields;

/** Templates are reviewed snapshots, never an additional source of effective authorization. */
public final class PermissionTemplateDtos {
    private PermissionTemplateDtos() {}
    public enum ApplyMode { MERGE, REPLACE }
    public record Template(UUID id, String name, String description, List<String> permissions,
                           long version, String updatedAt) {}
    public record Save(@NotBlank @Size(max=80) String name, @Size(max=1000) String description,
                       @NotNull @Size(max=3000) List<@NotBlank @Size(max=256) String> permissions,
                       @NotNull @PositiveOrZero Long expectedVersion) implements StrictFields {}
    public record Delete(@NotNull @PositiveOrZero Long expectedVersion) implements StrictFields {}
    public record Apply(@NotNull UUID templateId, @NotNull @PositiveOrZero Long templateVersion,
                        @NotNull ApplyMode mode) implements StrictFields {}
    public record Commit(@NotNull @Valid Apply request, @NotBlank String expectedFingerprint,
                         @Size(max=10000) List<String> sensitiveConfirmations) implements StrictFields {}
}
