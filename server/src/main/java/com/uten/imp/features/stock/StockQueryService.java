package com.uten.imp.features.stock;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.stock.dto.BalanceRow;
import com.uten.imp.features.stock.dto.MovementRow;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 库存查询服务：余额分页（按仓库/货品过滤）+ 流水分页（按仓库/货品/类型/日期过滤）。
 *
 * <p>名称（仓库/货品/颜色）不在此 JOIN，由前端按 id 用 master dict 解析（与采购单据同款）。
 */
@Service
@RequiredArgsConstructor
public class StockQueryService {

    /** 余额列排序白名单：前端列 key → JPA 实体属性名（数量可排序；命中才排序，否则默认 lastMovementDate DESC）。 */
    private static final Map<String, String> BALANCE_ALLOWED_SORT = Map.of("qty", "qty");

    /** 流水列排序白名单：前端列 key → JPA 实体属性名（日期/数量可排序；命中才排序，否则默认 transactionDate DESC）。 */
    private static final Map<String, String> MOVEMENT_ALLOWED_SORT = Map.of(
            "date", "transactionDate", "qty", "qty");

    private final StockBalanceRepository balanceRepo;
    private final StockMovementRepository movementRepo;

    @Transactional(readOnly = true)
    public PageResponse<BalanceRow> balances(UUID warehouseId, UUID goodsId, int page, int size,
                                             String sort, String order) {
        Specification<StockBalance> spec = (Root<StockBalance> root,
                                            jakarta.persistence.criteria.CriteriaQuery<?> q,
                                            CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (warehouseId != null) ps.add(cb.equal(root.get("warehouseId"), warehouseId));
            if (goodsId != null) ps.add(cb.equal(root.get("goodsId"), goodsId));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "lastMovementDate"), BALANCE_ALLOWED_SORT));
        Page<StockBalance> p = balanceRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toBalanceRow).getContent(), page, size,
                p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public PageResponse<MovementRow> movements(UUID warehouseId, UUID goodsId, Short movementType,
                                               OffsetDateTime dateFrom, OffsetDateTime dateTo,
                                               int page, int size, String sort, String order) {
        Specification<StockMovement> spec = (Root<StockMovement> root,
                                             jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (warehouseId != null) ps.add(cb.equal(root.get("warehouseId"), warehouseId));
            if (goodsId != null) ps.add(cb.equal(root.get("goodsId"), goodsId));
            if (movementType != null) ps.add(cb.equal(root.get("movementType"), movementType));
            if (dateFrom != null) ps.add(cb.greaterThanOrEqualTo(root.get("transactionDate"), dateFrom));
            if (dateTo != null) ps.add(cb.lessThanOrEqualTo(root.get("transactionDate"), dateTo));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "transactionDate"), MOVEMENT_ALLOWED_SORT));
        Page<StockMovement> p = movementRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toMovementRow).getContent(), page, size,
                p.getTotalElements(), p.getTotalPages());
    }

    private BalanceRow toBalanceRow(StockBalance b) {
        return new BalanceRow(b.getId(), b.getWarehouseId(), b.getGoodsId(), b.getColorId(),
                b.getQty(), b.getAmountLocal(), b.getLastMovementDate());
    }

    private MovementRow toMovementRow(StockMovement m) {
        return new MovementRow(m.getId(), m.getTransactionDate(), m.getMovementType(),
                m.getSourceDocType(), m.getSourceDocId(), m.getGoodsId(), m.getColorId(),
                m.getWarehouseId(), m.getDirection(), m.getQty(), m.getAmountLocal(), m.getRemark());
    }
}
