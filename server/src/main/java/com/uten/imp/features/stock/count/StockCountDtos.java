package com.uten.imp.features.stock.count;

import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

public final class StockCountDtos {
    private StockCountDtos() {}
    public record LineInput(@NotNull UUID goodsId, UUID colorId, @NotNull UUID unitId,
            @NotNull @Digits(integer=14,fraction=4) BigDecimal expectedQty,
            @Digits(integer=14,fraction=4) BigDecimal expectedWeightKg,
            boolean expectedWeightEstimated,
            @NotNull @DecimalMin("0") @Digits(integer=14,fraction=4) BigDecimal targetQty,
            @DecimalMin("0") @Digits(integer=14,fraction=4) BigDecimal targetWeightKg,
            boolean weightChanged, String materialSetupBasis, @NotNull Long goodsVersion) {}
    /**
     * 盘点送审。reason = 盘点说明, 选填: 不传、null、空串或只有空白都合法,
     * 由 StockCountRequestService.submit 统一归一化成 "" 存库, 去空白后超过 500 字回 422「盘点说明最多500字」
     * (V795 约束只留 500 字上限; 不在这里加 @Size, 免得被笼统的「输入不完整」文案盖住);
     * 前端原样提交输入框内容, 不自己判定必填。
     */
    public record Submit(@NotNull UUID warehouseId, String reason,
            @NotBlank @Pattern(regexp="[A-Za-z0-9._:-]{8,128}") String idempotencyKey,
            @NotEmpty @Size(max=500) List<@Valid LineInput> lines) {}
    public record Decision(@NotNull @PositiveOrZero Long expectedVersion,
            @NotBlank @Pattern(regexp="[A-Za-z0-9._:-]{8,128}") String idempotencyKey,
            @Size(max=500) String reason) {}
}
