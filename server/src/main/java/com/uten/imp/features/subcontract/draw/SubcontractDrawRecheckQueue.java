package com.uten.imp.features.subcontract.draw;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.SubcontractDrawRecheckPort;
import com.uten.imp.application.port.SubcontractOutboundWakePort;
import com.uten.imp.common.util.CanonicalFingerprint;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * ADR-143 §4.4 唤醒: 只在当前事务里追加 {@code SUBCONTRACT_DRAW_RECHECK} outbox 事件。
 *
 * <p>不读齐套、不加锁、不发通知; 同一事务同一货色只追加一条(去重键含事务号)。可领量在 outbox
 * 投递时(事务已提交)由 {@link SubcontractDrawRecheckService} 计算, 所以并发到货不会互相看不见而漏提醒。
 * 库存内核每笔入库与委外模块自己的预留释放、财务批准、改量都走这里; 回厂、退货、损耗结案等
 * 只改变订货明细结清状态的事实按订货明细追加(载荷 orderItemIds)。
 */
@Component
@RequiredArgsConstructor
public class SubcontractDrawRecheckQueue implements SubcontractOutboundWakePort {

    static final String AGGREGATE_TYPE = "SUBCONTRACT_DRAW_MATERIAL";
    static final String ORDER_ITEM_AGGREGATE_TYPE = "SUBCONTRACT_ORDER_ITEM";

    private final JdbcTemplate jdbc;
    private final BusinessEventPublisher events;

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void enqueueDrawRecheck(Collection<StockedDimension> dimensions) {
        if (dimensions == null || dimensions.isEmpty()) {
            return;
        }
        Set<Material> materials = new LinkedHashSet<>();
        for (StockedDimension dimension : dimensions) {
            if (dimension != null && dimension.goodsId() != null) {
                materials.add(new Material(dimension.goodsId(), dimension.colorId()));
            }
        }
        if (materials.isEmpty()) {
            return;
        }
        String transactionId = jdbc.queryForObject("SELECT pg_current_xact_id()::text", String.class);
        for (Material material : materials) {
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("goodsId", material.goodsId().toString());
            if (material.colorId() != null) {
                payload.put("colorId", material.colorId().toString());
            }
            events.publishOnce(SubcontractDrawRecheckPort.EVENT_TYPE, AGGREGATE_TYPE, material.goodsId(),
                    payload, "SC_DRAW_RECHECK:" + transactionId + ':' + material.goodsId() + ':'
                            + (material.colorId() == null ? "-" : material.colorId().toString()));
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void enqueueDrawRecheckForOrderItems(Collection<UUID> orderItemIds) {
        if (orderItemIds == null || orderItemIds.isEmpty()) {
            return;
        }
        List<UUID> ids = orderItemIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) {
            return;
        }
        List<String> idTexts = ids.stream().map(UUID::toString).toList();
        String transactionId = jdbc.queryForObject("SELECT pg_current_xact_id()::text", String.class);
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("orderItemIds", idTexts);
        events.publishOnce(SubcontractDrawRecheckPort.EVENT_TYPE, ORDER_ITEM_AGGREGATE_TYPE, ids.getFirst(),
                payload, "SC_DRAW_RECHECK:" + transactionId + ":items:" + CanonicalFingerprint.sha256(idTexts));
    }

    private record Material(UUID goodsId, UUID colorId) {
    }
}
