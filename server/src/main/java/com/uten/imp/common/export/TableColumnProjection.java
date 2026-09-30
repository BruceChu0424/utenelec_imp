package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;

/** Shared screen/preview/download projection. Definition payloads are descriptive, never authoritative. */
public record TableColumnProjection(@Size(max=300) String tableKey,
        @Pattern(regexp="[a-z][a-z0-9_]{0,99}") String scope,
        @NotEmpty @Size(max=160) List<@Valid Column> columns) {
    public record Column(@NotBlank @Size(max=120) String key, @Size(max=200) String label,
            @DecimalMin("1") @DecimalMax("2000") Double width, @Size(max=20) String type, JsonNode definition) { }
}
