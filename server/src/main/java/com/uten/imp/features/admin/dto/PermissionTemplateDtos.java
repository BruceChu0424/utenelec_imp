package com.uten.imp.features.admin.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import java.util.UUID;
import static com.uten.imp.features.admin.dto.PermissionTransferDtos.StrictFields;

/** Versioned templates and explicitly reviewed independent source assignments. */
public final class PermissionTemplateDtos {
    private PermissionTemplateDtos() {}
    public enum ApplyMode { MERGE, REPLACE }
    /** Total assigned objects, with explicit employee/department counts; legacy snapshot links are marked by Binding. */
    public record Template(UUID id, String name, String description, List<String> permissions,
                           long version, String updatedAt, long appliedCount, long appliedUserCount, long appliedDepartmentCount) {}
    public record Save(@NotBlank @Size(max=80) String name, @Size(max=1000) String description,
                       @NotNull @Size(max=3000) List<@NotBlank @Size(max=256) String> permissions,
                       @NotNull @PositiveOrZero Long expectedVersion,
                       @Size(max=3000) List<@NotBlank @Size(max=256) String> sensitiveConfirmations) implements StrictFields {
        public Save(String name,String description,List<String> permissions,Long expectedVersion) {
            this(name,description,permissions,expectedVersion,List.of());
        }
    }
    public record Delete(@NotNull @PositiveOrZero Long expectedVersion) implements StrictFields {}
    public record Apply(@NotNull UUID templateId, @NotNull @PositiveOrZero Long templateVersion,
                        @NotNull ApplyMode mode) implements StrictFields {}
    public record Binding(String kind, UUID targetId, UUID templateId, String templateName,
                          long templateVersion, boolean legacySnapshot) {}
    public record DeltaRequest(@Size(max=500) List<@NotNull UUID> userIds,
                               @Size(max=500) List<@NotNull UUID> departmentIds,
                               @Size(max=3000) List<@NotBlank @Size(max=256) String> grants,
                               @Size(max=3000) List<@NotBlank @Size(max=256) String> revokes) implements StrictFields {}
    public record DeltaCommit(@NotNull @Valid DeltaRequest request, @NotBlank String expectedFingerprint,
                              @Size(max=10000) List<String> sensitiveConfirmations) implements StrictFields {}
    public record BatchApply(@NotNull UUID templateId, @NotNull @PositiveOrZero Long templateVersion,
                             @NotNull ApplyMode mode,
                             @Size(max=500) List<@NotNull UUID> userIds,
                             @Size(max=500) List<@NotNull UUID> departmentIds) implements StrictFields {}
    public record BatchCommit(@NotNull @Valid BatchApply request, @NotBlank String expectedFingerprint,
                              @Size(max=10000) List<String> sensitiveConfirmations) implements StrictFields {}
    public record ExpectedBinding(@NotBlank @Pattern(regexp="user|department") String kind,
                                  @NotNull UUID targetId, @NotNull UUID templateId,
                                  @NotNull @PositiveOrZero Long templateVersion,
                                  @NotNull Boolean legacySnapshot) implements StrictFields {}
    public record Unbind(@Size(max=500) List<@NotNull UUID> userIds,
                         @Size(max=500) List<@NotNull UUID> departmentIds,
                         @Size(max=500) List<@NotNull @Valid ExpectedBinding> expectedBindings) implements StrictFields {}
    public record Commit(@NotNull @Valid Apply request, @NotBlank String expectedFingerprint,
                         @Size(max=10000) List<String> sensitiveConfirmations) implements StrictFields {}
}
