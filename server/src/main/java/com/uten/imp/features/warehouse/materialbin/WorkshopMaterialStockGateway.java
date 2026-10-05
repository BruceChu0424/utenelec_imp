package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.InventoryMovementCostReference.WorkshopMaterialBin;
import com.uten.imp.application.port.InventoryMovementCostReference.WorkshopMaterialBinKind;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.stock.dto.WorkshopMaterialDocumentCommand;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

/**
 * 内料仓唯一动库存的地方 (ADR-131 §5.2、§5.3、§5.7; 规格 §2.1)。
 *
 * <p>发料、收退回、其它耗用都经库存单据的内料仓通道建单审核 (库存侧自己登记单据, 调出一侧的流水带
 * 本次登记的来源引用); 盘点过账先记过账行, 再以它为来源引用记 21/22 型流水。价值一律由库存估值算,
 * 这里不带单价。调用方须先在同一事务里按库存维度一次锁定本次全部料 ({@link #lockInventory})。
 */
@Component
class WorkshopMaterialStockGateway {

    /** 调拨单上的一行: 对应领料单 (或退回单) 的哪一行。 */
    record TransferLine(UUID requisitionLineId, UUID goodsId, UUID colorId, UUID unitId, BigDecimal qty) {}

    /** 一张调拨单 (一个叶仓一张)。 */
    record TransferCommand(WorkshopMaterialDocumentCommand.Kind kind, UUID binWarehouseId, UUID leafWarehouseId,
                           UUID requisitionId, UUID workshopDepartmentId, UUID receiverEmployeeId, String remark,
                           List<TransferLine> lines, UUID periodId, LocalDate businessDate,
                           boolean supplement, String supplementReason) {}

    record TransferPosted(UUID documentId, String billNo, UUID leafWarehouseId, UUID periodId, boolean supplement,
                          BigDecimal qty) {}

    record OtherIssuePosted(UUID documentId, String billNo, UUID itemId, UUID movementId) {}

    private final StockDocService stockDocs;
    private final StockService stock;
    private final NamedParameterJdbcTemplate db;
    private final SecurityContextCurrentUser currentUser;

    WorkshopMaterialStockGateway(StockDocService stockDocs, StockService stock, NamedParameterJdbcTemplate db,
                                 SecurityContextCurrentUser currentUser) {
        this.stockDocs = stockDocs;
        this.stock = stock;
        this.db = db;
        this.currentUser = currentUser;
    }

    /** 本命令涉及的全部料一次锁定 (第一笔入库流水之后不能再补锁新维度)。 */
    void lockInventory(Collection<WorkshopMaterialBinSupport.Material> materials) {
        stock.lockInventory(materials.stream().map(m -> new InventoryKey(m.goodsId(), m.colorId()))
                .distinct().toList());
    }

    /**
     * 建一张调拨单并审核, 写调拨关联 (内料仓一侧的流水、所属期间、业务日期) 与明细实发数量。
     * 发料: 叶仓 → 内料仓 (内料仓一侧 7 型调入); 收退回: 内料仓 → 叶仓 (内料仓一侧 8 型调出)。
     */
    TransferPosted transfer(TransferCommand command) {
        List<WorkshopMaterialDocumentCommand.Line> lines = new ArrayList<>();
        for (TransferLine line : command.lines()) {
            lines.add(new WorkshopMaterialDocumentCommand.Line(line.goodsId(), line.colorId(), line.unitId(),
                    BigDecimal.ONE, line.qty(), null));
        }
        WorkshopMaterialDocumentCommand.Posted posted = stockDocs.createAndApproveWorkshopMaterialDocument(
                new WorkshopMaterialDocumentCommand(
                        command.kind(), command.binWarehouseId(), command.leafWarehouseId(), command.requisitionId(),
                        null, command.workshopDepartmentId(), command.receiverEmployeeId(), command.businessDate(),
                        command.remark(), lines));
        if (posted.lines().size() != command.lines().size()) {
            throw new ApiException(ErrorCode.CONFLICT, "内料仓调拨单的明细与领料单对不上, 请刷新后重试");
        }
        UUID actor = currentUser.requireId();
        BigDecimal total = BigDecimal.ZERO;
        for (int index = 0; index < posted.lines().size(); index++) {
            WorkshopMaterialDocumentCommand.PostedLine row = posted.lines().get(index);
            TransferLine source = command.lines().get(index);
            db.update("""
                    INSERT INTO workshop_material_requisition_postings(
                        line_id, stock_document_item_id, leaf_warehouse_id, bin_warehouse_id, goods_id, color_id,
                        movement_id, qty, period_id, business_date, is_supplement, supplement_reason, created_by)
                    VALUES (:line, :item, :leaf, :bin, :goods, CAST(:color AS uuid), :movement, :qty, :period,
                            :businessDate, :supplement, :reason, :actor)
                    """, new MapSqlParameterSource()
                    .addValue("line", source.requisitionLineId())
                    .addValue("item", row.itemId())
                    .addValue("leaf", command.leafWarehouseId())
                    .addValue("bin", command.binWarehouseId())
                    .addValue("goods", row.goodsId())
                    .addValue("color", row.colorId() == null ? null : row.colorId().toString())
                    .addValue("movement", row.binMovementId())
                    .addValue("qty", row.baseQty())
                    .addValue("period", command.periodId())
                    .addValue("businessDate", command.businessDate())
                    .addValue("supplement", command.supplement())
                    .addValue("reason", command.supplement() ? command.supplementReason() : null)
                    .addValue("actor", actor));
            db.update("""
                    UPDATE workshop_material_requisition_lines SET fulfilled_qty = fulfilled_qty + :qty
                    WHERE id = :line
                    """, new MapSqlParameterSource("qty", row.baseQty()).addValue("line", source.requisitionLineId()));
            total = total.add(row.baseQty());
        }
        return new TransferPosted(posted.documentId(), posted.billNo(), command.leafWarehouseId(), command.periodId(),
                command.supplement(), total);
    }

    /** 其它耗用: 从内料仓其它出库 (12 型), 回填耗用记录的明细与流水。耗用记录须已先落库。 */
    OtherIssuePosted otherIssue(UUID otherIssueId, UUID binWarehouseId, UUID workshopDepartmentId, UUID goodsId,
                                UUID colorId, UUID unitId, BigDecimal qty, LocalDate businessDate, String remark) {
        WorkshopMaterialDocumentCommand.Posted posted = stockDocs.createAndApproveWorkshopMaterialDocument(
                new WorkshopMaterialDocumentCommand(
                        WorkshopMaterialDocumentCommand.Kind.OTHER_ISSUE, binWarehouseId, null, null, otherIssueId,
                        workshopDepartmentId, null, businessDate, remark,
                        List.of(new WorkshopMaterialDocumentCommand.Line(goodsId, colorId, unitId, BigDecimal.ONE,
                                qty, null))));
        if (posted.lines().size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "其它耗用的出库单明细不对, 请刷新后重试");
        }
        WorkshopMaterialDocumentCommand.PostedLine row = posted.lines().getFirst();
        db.update("""
                UPDATE workshop_material_other_issues SET stock_document_item_id = :item, movement_id = :movement
                WHERE id = :id
                """, new MapSqlParameterSource("item", row.itemId()).addValue("movement", row.binMovementId())
                .addValue("id", otherIssueId));
        return new OtherIssuePosted(posted.documentId(), posted.billNo(), row.itemId(), row.binMovementId());
    }

    /**
     * 一条盘点过账: 过账行 → 以它为来源引用记 21/22 型流水 → 回填流水。
     * CONSUME 21 型出 / CONSUME_REVERSE 21 型原路入 / GAIN 22 型入 / GAIN_REVERSE 22 型原路出。
     */
    UUID countPosting(UUID periodLineId, UUID countId, UUID binWarehouseId, UUID goodsId, UUID colorId, UUID unitId,
                      String kind, UUID reversesPostingId, BigDecimal qty, LocalDate businessDate, String reason) {
        UUID postingId = UUID.randomUUID();
        db.update("""
                INSERT INTO workshop_material_count_postings(
                    id, period_line_id, count_id, bin_warehouse_id, goods_id, color_id, kind, reverses_posting_id,
                    qty, business_date, reason, created_by)
                VALUES (:id, :line, :count, :bin, :goods, CAST(:color AS uuid), :kind, CAST(:reverses AS uuid),
                        :qty, :businessDate, :reason, :actor)
                """, new MapSqlParameterSource()
                .addValue("id", postingId)
                .addValue("line", periodLineId)
                .addValue("count", countId)
                .addValue("bin", binWarehouseId)
                .addValue("goods", goodsId)
                .addValue("color", colorId == null ? null : colorId.toString())
                .addValue("kind", kind)
                .addValue("reverses", reversesPostingId == null ? null : reversesPostingId.toString())
                .addValue("qty", qty)
                .addValue("businessDate", businessDate)
                .addValue("reason", reason)
                .addValue("actor", currentUser.requireId()));
        WorkshopMaterialBinKind binKind = WorkshopMaterialBinKind.valueOf(kind);
        short type = kind.startsWith("CONSUME")
                ? StockService.TYPE_WORKSHOP_MATERIAL_CONSUME : StockService.TYPE_WORKSHOP_MATERIAL_GAIN;
        short direction = "CONSUME".equals(kind) || "GAIN_REVERSE".equals(kind)
                ? StockService.DIR_OUT : StockService.DIR_IN;
        UUID movementId = stock.recordMovement(new StockService.MovementRequest(
                BusinessTime.startOfDay(businessDate), type, StockService.SRC_WORKSHOP_MATERIAL_COUNT, countId,
                periodLineId, goodsId, colorId, binWarehouseId, direction, qty, unitId, BigDecimal.ONE, null,
                remark(kind), null, new WorkshopMaterialBin(postingId, binKind))).movementId();
        db.update("UPDATE workshop_material_count_postings SET movement_id = :movement WHERE id = :id",
                new MapSqlParameterSource("movement", movementId).addValue("id", postingId));
        return postingId;
    }

    private static String remark(String kind) {
        return switch (kind) {
            case "CONSUME" -> "内料仓盘点耗用";
            case "CONSUME_REVERSE" -> "内料仓盘点耗用冲回";
            case "GAIN" -> "内料仓盘盈";
            default -> "内料仓盘盈冲回";
        };
    }
}
