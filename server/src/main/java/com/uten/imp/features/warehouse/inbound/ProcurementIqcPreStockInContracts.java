package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 到货「先入库后质检」(上架待检, ADR-090 / V596) 的无金额契约。
 *
 * <p>先入库 = 实物先上架落位(实际记账叶仓 + 库位)，待检明细行记住位置；品质部到库位检验，
 * 合格由系统按记录的位置自动完成正式入库(V446 同一套批次/流水/价值守卫)，不合格从库位
 * 取出走 V440 既有退回链路。本契约只承载位置与数量，不含单价、金额、币种。
 */
public final class ProcurementIqcPreStockInContracts {

    private ProcurementIqcPreStockInContracts() {
    }

    /** 逐行指定上架仓与库位；同一待检明细行只能出现一次。 */
    public record PreStockInRequest(
            @NotEmpty @Size(max = 100) List<@Valid PreStockInItem> items) {
    }

    public record PreStockInItem(
            @NotNull @JsonSerialize(using = ToStringSerializer.class) UUID inspectionItemId,
            @NotNull @JsonSerialize(using = ToStringSerializer.class) UUID warehouseId,
            @NotBlank @Size(max = 100) String place) {
    }

    /**
     * 上架结果：{@code stockedLineCount} = 本次真正写入/改动位置的明细行数；
     * {@code replayedLineCount} = 位置未变化、按原事实静默重放的行数。
     */
    public record PreStockInResult(
            String receiptType,
            @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            int requestedLineCount,
            int stockedLineCount,
            int replayedLineCount,
            OffsetDateTime stockedAt) {
    }

    /** 已上架位置的只读投影(挂在待检明细/检查结果明细/退回案件上)。 */
    public record PreStockedLocation(
            @JsonSerialize(using = ToStringSerializer.class) UUID warehouseId,
            String warehouseName,
            String place,
            OffsetDateTime stockedAt,
            String stockedByName) {

        public String label() {
            String warehouse = warehouseName == null || warehouseName.isBlank()
                    ? (warehouseId == null ? "" : warehouseId.toString()) : warehouseName;
            return place == null || place.isBlank() ? warehouse : warehouse + " / " + place;
        }
    }
}
