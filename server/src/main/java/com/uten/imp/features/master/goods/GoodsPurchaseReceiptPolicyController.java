package com.uten.imp.features.master.goods;

import com.uten.imp.common.concurrency.OptimisticLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品主档「采购默认」区的采购允许超收%(ADR-144)。只改这一个记忆值, 不走整张货品 PUT;
 * 比例不是价格或成本, 只要 goods:edit 与货品写范围。空 = 清除记忆(下次新增行不再预填)。
 */
@RestController
@RequiredArgsConstructor
public class GoodsPurchaseReceiptPolicyController {
    private final EntityManager em;
    private final GoodsService goods;
    private final TxSessionVars tx;

    public record Policy(
            @DecimalMin("0.00") @DecimalMax("100.00") @Digits(integer = 3, fraction = 2)
            BigDecimal allowedOverReceiptPct,
            @NotNull Long version) {}

    @PutMapping("/api/master/goods/{id}/purchase-receipt-policy")
    @PreAuthorize("hasAuthority('goods:edit')")
    @Transactional
    public GoodsDetail update(@PathVariable UUID id, @Valid @RequestBody Policy policy) {
        tx.bind();
        Goods entity = em.find(Goods.class, id, LockModeType.PESSIMISTIC_WRITE);
        if (entity == null || entity.isDeleted()) throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        goods.requireWritable(entity);
        OptimisticLocks.requireUpToDate(entity.getVersion(), policy.version());
        entity.setPurchaseAllowedOverReceiptPct(policy.allowedOverReceiptPct());
        em.flush();
        return goods.detail(id);
    }
}
