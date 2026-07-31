package com.uten.imp.features.stock.dto;

import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 授权库存余额调整请求。
 *
 * <p>{@code expectedQty} 是操作者在页面看到的旧值，用于防止并发出入库被覆盖；
 * {@code targetQty} 是调整完成后的目标余额，不是增减量。
 */
@Getter
@Setter
public class StockBalanceAdjustmentRequest {

    /**
     * 一次用户操作的幂等键。网络超时后重试必须复用同一个值，
     * 避免“服务端已成功、客户端未收到响应”时生成第二张调整单。
     */
    @NotBlank
    @Size(min = 8, max = 128)
    @Pattern(regexp = "[A-Za-z0-9._:-]+")
    private String idempotencyKey;

    @NotNull
    private UUID warehouseId;

    @NotNull
    private UUID goodsId;

    private UUID colorId;

    @NotNull
    @Digits(integer = 14, fraction = 4)
    private BigDecimal expectedQty;

    @NotNull
    @PositiveOrZero
    @Digits(integer = 14, fraction = 4)
    private BigDecimal targetQty;

    @NotBlank
    @Size(max = 500)
    private String reason;
}
