package com.uten.imp.features.stock.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 不良品专门通道一次建单并过账(ADR-146)。
 *
 * @param kind            TO_DEFECTIVE 转不良品仓(良品仓 -> 不良品仓) / DEFECT_RELEASE 不良复判转回(不良品仓 -> 良品仓)
 * @param fromWarehouseId 调出仓
 * @param toWarehouseId   调入仓
 * @param reason          转不良的原因 / 复判说明(必填, 不超过 500 字)
 * @param billDate        单据日期(空 = 今天)
 * @param requestKey      客户端重试键(同一制单人唯一, 重试回放原单)
 * @param items           货品明细(不逐行指定仓库)
 */
public record StockDefectiveMoveRequest(
        @NotBlank String kind,
        @NotNull UUID fromWarehouseId,
        @NotNull UUID toWarehouseId,
        @NotBlank @Size(max = 500) String reason,
        LocalDate billDate,
        @NotBlank @Pattern(regexp = "[A-Za-z0-9._:-]{8,128}") String requestKey,
        @Valid @NotNull @Size(min = 1, max = RequestLimits.DOCUMENT_LINES) List<StockDocItemLine> items) {
}
