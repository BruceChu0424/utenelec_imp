package com.uten.imp.common.platformcolumns;

import jakarta.validation.Valid;
import java.util.List;
import java.util.UUID;
import lombok.Getter;
import lombok.Setter;

/** Explicit business-save payload; resource scope always comes from the server annotation. */
@Getter
@Setter
public abstract class PlatformColumnLineInput {
    @Valid private Fields platformFields;
    /** Server-only identity for explicit domain splitting; never deserialize caller tokens. */
    @com.fasterxml.jackson.annotation.JsonIgnore private UUID platformSaveToken;
    public record Fields(UUID sourceRecordId, long expectedVersion,
                         List<PlatformColumnContracts.CellInput> cells) { }
}
