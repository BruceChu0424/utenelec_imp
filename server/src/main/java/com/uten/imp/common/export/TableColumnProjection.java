package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.annotation.JsonCreator;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

/** Shared screen/preview/download projection. Definition payloads are descriptive, never authoritative. */
@JsonPropertyOrder({"tableKey", "scope", "columns"})
public final class TableColumnProjection {
    @Size(max=300)
    private final String tableKey;
    @Pattern(regexp="[a-z][a-z0-9_]{0,99}")
    private final String scope;
    @NotEmpty @Size(max=160)
    private final List<@Valid Column> columns;

    @JsonCreator
    public TableColumnProjection(@JsonProperty("tableKey") @Size(max=300) String tableKey,
            @JsonProperty("scope") @Pattern(regexp="[a-z][a-z0-9_]{0,99}") String scope,
            @JsonProperty("columns") @NotEmpty @Size(max=160) List<@Valid Column> columns) {
        // Preserve malformed/null entries for the shared validator while
        // freezing the caller's list before authorization and publication.
        this.tableKey = tableKey;
        this.scope = scope;
        this.columns = columns == null ? null
                : Collections.unmodifiableList(new ArrayList<>(columns));
    }

    @JsonProperty("tableKey")
    @Size(max=300)
    public String tableKey() {
        return tableKey;
    }

    @JsonProperty("scope")
    @Pattern(regexp="[a-z][a-z0-9_]{0,99}")
    public String scope() {
        return scope;
    }

    @JsonProperty("columns")
    @NotEmpty @Size(max=160)
    public List<@Valid Column> columns() {
        // This is a view of our private snapshot, never the request-owned list.
        return columns == null ? null : Collections.unmodifiableList(columns);
    }

    @Override
    public boolean equals(Object other) {
        return this == other || other instanceof TableColumnProjection that
                && Objects.equals(tableKey, that.tableKey)
                && Objects.equals(scope, that.scope)
                && Objects.equals(columns, that.columns);
    }

    @Override
    public int hashCode() {
        int hash = Objects.hashCode(tableKey);
        hash = 31 * hash + Objects.hashCode(scope);
        return 31 * hash + Objects.hashCode(columns);
    }

    @Override
    public String toString() {
        return "TableColumnProjection[tableKey=" + tableKey + ", scope=" + scope
                + ", columns=" + columns + "]";
    }
    public record Column(@NotBlank @Size(max=120) String key, @Size(max=200) String label,
            @DecimalMin("1") @DecimalMax("2000") Double width, @Size(max=20) String type, JsonNode definition) {
        public Column {
            // Missing and explicit JSON null describe the same absent definition.
            // Preserve record equality across persistence so the same named export job
            // cannot spuriously conflict after Jackson materializes a NullNode.
            if(definition!=null&&definition.isNull())definition=null;
        }
    }
}
