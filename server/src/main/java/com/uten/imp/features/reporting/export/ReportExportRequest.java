package com.uten.imp.features.reporting.export;

import com.uten.imp.common.export.TableColumnProjection;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.Map;
import java.util.UUID;

/** Passwords are supplied only when downloading; they are never persisted in the task. */
public record ReportExportRequest(@NotNull UUID id,
        @Pattern(regexp="sales|purchase|subcontract|production|stock|finance|where_used|master|workbench_purchase|workbench_subcontract|audit|goods_actual_cost") @NotNull String domain,
        @NotBlank @Size(max=100) String report,
        @Size(max=80) Map<@NotBlank @Size(max=120) String, @Size(max=60000) String> parameters,
        @Size(max=100) String sort, @Pattern(regexp="(?i)asc|desc") String order,
        @Valid TableColumnProjection columnProjection,
        @Pattern(regexp="xlsx|pdf") String format) implements com.uten.imp.application.port.ReportExportQuery {
    public ReportExportRequest {
        parameters = parameters == null ? Map.of() : Map.copyOf(parameters);
        format = format == null ? "xlsx" : format;
    }
    public ReportExportRequest(UUID id,String domain,String report,Map<String,String> parameters,String sort,String order,TableColumnProjection projection) {
        this(id,domain,report,parameters,sort,order,projection,"xlsx");
    }
}
