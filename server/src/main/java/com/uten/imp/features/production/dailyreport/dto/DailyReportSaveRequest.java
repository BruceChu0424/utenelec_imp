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

    /**
     * 报工同页登记的本次实际用料(V583)。整单一条需求只登记一次，所以放在请求头而不是
     * 明细行上：同一个执行工单出现在多个成品行时，它的物料只算一份额度。
     *
     * <p>草稿阶段只是事实登记，审核时才转成 CONSUMED 结算。
     */
    @Valid
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<DailyReportMaterialUsageLine> materialLines;

    /**
     * 收尾余料退仓意愿：最后一次报工时车间确认「剩下的料退回仓库」。审核时先结实耗、
     * 再按剩余可退量生成退料单；没有可退量就什么都不做，不打扰仓库。
     */
    private Boolean surplusReturnRequested;
}
