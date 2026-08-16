package com.uten.imp.features.production.plan.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 生产计划详情（含明细行）。 */
@Getter
@AllArgsConstructor
public class PlanDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private String fStyle;
    private LocalDate deliveryDate;
    private UUID departmentId;
    private String workshopName;
    private String workerName;
    private String sellerName;
    private UUID sellerId;
    private UUID workerId;
    private UUID makerId;
    private UUID approverId;
    private Integer makerLegacyId;
    private Integer approverLegacyId;
    private String remark;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private boolean canceled;
    private String sourceDocNo;
    /** 自动补产的来源报工 UUID；sourceDocNo 仅是创建时快照。 */
    private UUID sourceDailyReportId;
    private UUID materialAnalysisId;
    private UUID materialAnalysisItemId;
    private List<String> allowedActions;
    private List<PlanItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** 部分溯源投影：明确关联的来源销售订单。 */
    private List<PlanTraceLink> traceSalesOrders;
    /** 部分溯源投影：本计划关联的领料单与成品入库单。 */
    private List<PlanTraceLink> traceMaterialDraws;
    /** 部分溯源投影：旧 MRP 或同一分析产品逐路径 action 生成的采购申请。 */
    private List<PlanTraceLink> tracePurchaseRequests;
    /** 部分溯源投影：同一分析产品逐路径 action 生成的委外申请。 */
    private List<PlanTraceLink> traceSubcontractApplications;
    /** 部分溯源投影：已审核生产报工单（按计划行归属聚合，去重）。 */
    private List<PlanTraceLink> traceDailyReports;
}
