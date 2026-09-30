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

/** Keeps the existing subcontract allowance editable without a full goods PUT. */
@RestController
@RequiredArgsConstructor
public class GoodsSubcontractLossPolicyController {
    private final EntityManager em;
    private final GoodsService goods;
    private final TxSessionVars tx;

    public record Policy(@NotNull Long expectedVersion,
            @DecimalMin("0") @DecimalMax("100") @Digits(integer = 3, fraction = 2) BigDecimal percent) {}

    @PutMapping("/api/master/goods/{id}/subcontract-loss-policy")
    @PreAuthorize("hasAuthority('goods:edit') and hasAuthority('goods:cost:view')")
    @Transactional
    public GoodsDetail update(@PathVariable UUID id, @Valid @RequestBody Policy policy) {
        tx.bind();
        Goods entity = em.find(Goods.class, id, LockModeType.PESSIMISTIC_WRITE);
        if (entity == null || entity.isDeleted()) throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        goods.requireWritable(entity);
        OptimisticLocks.requireUpToDate(entity.getVersion(), policy.expectedVersion());
        entity.setSubcontractAllowedLossPct(policy.percent());
        em.flush();
        return goods.detail(id);
    }
}
