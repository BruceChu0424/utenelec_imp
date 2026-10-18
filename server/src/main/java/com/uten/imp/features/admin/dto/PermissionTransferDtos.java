package com.uten.imp.features.admin.dto;

import com.fasterxml.jackson.annotation.JsonAnySetter;
import com.fasterxml.jackson.databind.JsonNode;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Portable codes and explicit destination mappings; source keys are never destination identities. */
public final class PermissionTransferDtos {
    private PermissionTransferDtos() {}
    public interface StrictFields {
        @JsonAnySetter
        default void rejectUnknown(String key, JsonNode ignored) {
            throw new IllegalArgumentException("权限配置包含不支持的字段：" + key);
        }
    }
    public record DepartmentConfiguration(String key, String code, String name, List<String> permissions) implements StrictFields {}
    public record UserConfiguration(String key, String employeeCode, String employeeName, String loginAccount,
            List<String> grants, List<String> revokes, List<String> effective,
            List<String> delegationPermissions, Map<String, List<String>> dataScopes,
            String accountStatus, String employeeStatus, Boolean restorable, String restoreReason,
            List<StoredOverride> storedOverrides) implements StrictFields {
        /** Early v1 documents did not annotate eligibility; live destination checks still apply. */
        public UserConfiguration(String key,String employeeCode,String employeeName,String loginAccount,
                List<String> grants,List<String> revokes,List<String> effective,List<String> delegationPermissions,
                Map<String,List<String>> dataScopes) {
            this(key,employeeCode,employeeName,loginAccount,grants,revokes,effective,delegationPermissions,dataScopes,
                    null,null,null,null,List.of());
        }
    }
    public record StoredOverride(String code,String effect,boolean active,String authoritySource) implements StrictFields {}
    public record ScopeOwner(String key, String code, String name) implements StrictFields {}
    public record Backup(String format, int version, String exportedAt, List<String> baseline,
            List<DepartmentConfiguration> departments, List<UserConfiguration> users, List<ScopeOwner> scopeOwners) implements StrictFields {}
    public record Mapping(@NotBlank String sourceKey, UUID targetId) implements StrictFields {}
    public record ImportRequest(@NotNull @Valid Backup configuration, boolean importBaseline,
            @Size(max=1000) List<@Valid Mapping> departments, @Size(max=1000) List<@Valid Mapping> users,
            boolean importDataScopes, @Size(max=5000) List<@Valid Mapping> owners) implements StrictFields {}
    public record ImportCommit(@NotNull @Valid ImportRequest request, @NotBlank String expectedFingerprint,
            @Size(max=10000) List<String> sensitiveConfirmations) implements StrictFields {}
    public record CopySnapshot(UUID sourceUserId, String sourceLabel, List<String> permissions,
            String fingerprint, List<String> delegationPermissions) {}
    public record CopyRequest(@NotNull UUID sourceUserId, @NotBlank String sourceFingerprint) implements StrictFields {}
    public record CopyCommit(@NotNull @Valid CopyRequest request, @NotBlank String expectedFingerprint,
            @Size(max=10000) List<String> sensitiveConfirmations) implements StrictFields {}
    public record Change(String kind, String sourceKey, UUID targetId, String label,
            List<String> added, List<String> removed) {}
    public record SensitiveAddition(String key, String label, String permissionCode, String targetLabel) {}
    public record Suggestion(String kind, String sourceKey, UUID targetId, String label) {}
    public record Preview(String fingerprint, boolean canApply, List<String> issues, List<Change> changes,
            List<SensitiveAddition> sensitiveAdditions, List<Suggestion> suggestions,
            List<String> pinnedBaselineAdditions, List<String> notes) {}
    public record Result(boolean changed, List<Change> changes) {}
}
