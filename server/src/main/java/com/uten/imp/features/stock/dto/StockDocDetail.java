package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 仓库单据详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class StockDocDetail {
    private UUID id;
    private Integer legacyId;
    private String docType;
    private String billNo;
    private LocalDate billDate;
    private UUID warehouseId;
    private UUID toWarehouseId;
    private UUID supplierId;
    private UUID clientId;
    private UUID workerId;
    private UUID makerId;
    private UUID approverId;
    private String assTeam;
    private String planNo;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    /** 自动成品入库的来源报工 UUID；sourceDocNo 仅是创建时快照。 */
    private UUID sourceDailyReportId;
    /** 领料车间/部门（DRAW 用）。 */
    private UUID departmentId;
    /** 出库进度（仅 DRAW）：0未出库/1部分出库/2已出完。 */
    private Short issueStatus;
    private List<StockDocItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** 是否由生产链自动生成并持有，禁止通用仓库 CRUD 改写。 */
    private boolean productionLinked;
    /** 当前单据是否允许通过通用仓库编辑入口修改。 */
    private boolean canEdit;
    /** 当前单据是否允许通过通用仓库入口删除。 */
    private boolean canDelete;
    /** 只读原因；为空表示没有额外来源限制。 */
    private String restrictionReason;
    /** 来源生产计划 id（经 plan_draw_links 反查；仓库端展示 planNo 时可点击跳转计划详情；无关联为 null）。 */
    private UUID sourcePlanId;
    /** 仓库实收确认决策（ACCEPTED/PARTIAL/REJECTED）；无确认记录为 null。 */
    private String finishedInboundDecision;
    /** 仓库实收差异/拒收原因（确认记录为权威，不写入被守卫的单据备注列）。 */
    private String finishedInboundVarianceReason;
}
