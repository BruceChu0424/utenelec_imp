package com.uten.imp.features.companyfiles;

import jakarta.validation.Valid;
import jakarta.validation.constraints.*;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

public final class CompanyFileDtos {
    private CompanyFileDtos() {}

    public record Entry(
            UUID id,
            UUID parentId,
            String kind,
            String name,
            String description,
            long version,
            long position,
            boolean passwordProtected,
            boolean locked,
            boolean deleted,
            Instant deletedAt,
            Instant createdAt,
            Instant updatedAt,
            String createdByName,
            String updatedByName,
            UUID attachmentId,
            Long sizeBytes,
            String contentType,
            boolean pending,
            List<String> allowedActions) {}

    public record Breadcrumb(UUID id, String name, boolean passwordProtected, boolean locked) {}

    public record Listing(
            Entry folder,
            List<Breadcrumb> breadcrumbs,
            List<Entry> entries,
            long total,
            int page,
            int size,
            List<String> allowedActions,
            boolean canReorder) {}

    public record Create(
            UUID parentId,
            @NotBlank @Size(max = 180) String name,
            @Size(max = 2000) String description,
            UUID requestId,
            @Valid InitialAccess access) {
        public Create(UUID parentId, String name, String description) {
            this(parentId, name, description, null, null);
        }

        public Create(UUID parentId, String name, String description, UUID requestId) {
            this(parentId, name, description, requestId, null);
        }
    }

    /** New-object read policy only; it never configures system permissions. */
    public record InitialAccess(
            @NotNull Boolean inheritPermissions,
            @NotNull @Size(max = 100) List<@Valid Rule> rules,
            @Size(max = 128) String password) {}

    public record Edit(
            @NotBlank @Size(max = 180) String name,
            @Size(max = 2000) String description,
            @NotNull @PositiveOrZero Long version) {}

    public record Version(@NotNull @PositiveOrZero Long version) {}

    public record Complete(@NotNull UUID attachmentId, @NotNull @PositiveOrZero Long version) {}

    public record Move(UUID parentId, @NotNull @PositiveOrZero Long version) {}

    public record Reorder(
            UUID parentId,
            @NotNull @Size(min = 1, max = 500) List<@NotNull UUID> orderedIds,
            @NotNull @Size(min = 1, max = 500) Map<UUID, @NotNull @PositiveOrZero Long> versions) {
        public Reorder(UUID parentId, List<UUID> orderedIds) {
            this(parentId, orderedIds, Map.of());
        }
    }

    public record Rule(
            @NotBlank String subjectType,
            @NotNull UUID subjectId,
            String subjectName,
            @NotBlank String effect,
            @NotEmpty @Size(max = 9) List<@NotBlank String> actions) {}

    public record Permissions(
            boolean inheritPermissions,
            @NotNull @Size(max = 100) List<@Valid Rule> rules,
            @NotNull @PositiveOrZero Long version) {}

    public record Password(
            @Size(max = 128) String password, @NotNull @PositiveOrZero Long version) {}

    public record Unlock(@NotBlank @Size(max = 128) String password) {}

    public record Unlocked(Instant expiresAt) {}

    public record Principal(UUID id, String name, String detail, String type) {}
}
