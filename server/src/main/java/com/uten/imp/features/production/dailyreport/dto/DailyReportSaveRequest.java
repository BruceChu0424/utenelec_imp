package com.uten.imp.features.production.dailyreport.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 生产日报新建/编辑请求。 */
@Getter
@Setter
public class DailyReportSaveRequest {
    /** Required for create; excluded from the canonical request hash. */
    @Size(min = 8, max = 128)
    private String idempotencyKey;
    /** Required for PUT; compared with the persisted rowVersion before mutation. */
    @Min(0)
    private Long expectedVersion;
    private String billNo;
    @NotNull private LocalDate billDate;
    private UUID warehouseId;
    private UUID departmentId;
    private String workshopName;
    /**
     * Ordered whole-report participants. This is not line-level contribution
     * or piece-rate/payroll evidence. New clients use this list; workerId is
     * retained as the first responsible employee for legacy compatibility.
     */
    @Size(max = 100)
    private List<@NotNull UUID> workerIds;
    private UUID workerId;
    private UUID supplierId;
    private String remark;
    private String sourceDocNo;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<DailyReportItemLine> items;
}
