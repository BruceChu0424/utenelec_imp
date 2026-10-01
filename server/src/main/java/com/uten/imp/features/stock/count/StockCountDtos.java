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
    public record Submit(@NotNull UUID warehouseId, @NotBlank @Size(max=500) String reason,
            @NotBlank @Pattern(regexp="[A-Za-z0-9._:-]{8,128}") String idempotencyKey,
            @NotEmpty @Size(max=500) List<@Valid LineInput> lines) {}
    public record Decision(@NotNull @PositiveOrZero Long expectedVersion,
            @NotBlank @Pattern(regexp="[A-Za-z0-9._:-]{8,128}") String idempotencyKey,
            @Size(max=500) String reason) {}
}
