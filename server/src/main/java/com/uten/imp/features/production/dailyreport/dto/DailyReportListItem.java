package com.uten.imp.features.production.dailyreport.dto;

import lombok.Getter;
import com.fasterxml.jackson.annotation.JsonInclude;

import java.time.LocalDate;
import java.util.UUID;
import java.util.List;

/** 生产日报列表行。 */
@Getter
public class DailyReportListItem extends com.uten.imp.common.history.DocumentHistoryMetadata {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID warehouseId;
    private UUID departmentId;
    private String workshopName;
    private UUID workerId;
    private UUID supplierId;
    private Short status;
    private boolean closed;
    private boolean canceled;
    private Integer legacyId;

    @lombok.Setter
    @JsonInclude(JsonInclude.Include.NON_NULL)
    private Integer draftClaimsVersion;
    @lombok.Setter
    @JsonInclude(JsonInclude.Include.NON_NULL)
    private List<DailyReportDraftClaim> draftClaims;

    public DailyReportListItem(UUID id, String billNo, LocalDate billDate, UUID warehouseId,
                               UUID departmentId, String workshopName, UUID workerId, UUID supplierId,
                               Short status, boolean closed, boolean canceled, Integer legacyId) {
        this.id=id;this.billNo=billNo;this.billDate=billDate;this.warehouseId=warehouseId;
        this.departmentId=departmentId;this.workshopName=workshopName;this.workerId=workerId;
        this.supplierId=supplierId;this.status=status;this.closed=closed;this.canceled=canceled;
        this.legacyId=legacyId;
    }

}
