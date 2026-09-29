package com.uten.imp.features.notice.outbox;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessOutboxDomainHandler;
import com.uten.imp.features.notice.ChainNoticeService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * Claims one event with {@code FOR UPDATE SKIP LOCKED}. Notice inserts and the
 * delivered marker share this transaction, giving crash-safe at-least-once
 * processing without duplicate committed notices.
 */
@Service
public class BusinessOutboxProcessor {

    private final JdbcTemplate jdbc;
    private final ObjectMapper objectMapper;
    private final ChainNoticeService chainNotice;
    private final List<BusinessOutboxDomainHandler> domainHandlers;

    @Autowired
    public BusinessOutboxProcessor(
            JdbcTemplate jdbc,
            ObjectMapper objectMapper,
            ChainNoticeService chainNotice,
            List<BusinessOutboxDomainHandler> domainHandlers) {
        this.jdbc = jdbc;
        this.objectMapper = objectMapper;
        this.chainNotice = chainNotice;
        this.domainHandlers = domainHandlers == null ? List.of() : List.copyOf(domainHandlers);
    }

    /** Test/backward-compatible constructor for an outbox without domain projections. */
    public BusinessOutboxProcessor(
            JdbcTemplate jdbc,
            ObjectMapper objectMapper,
            ChainNoticeService chainNotice) {
        this(jdbc, objectMapper, chainNotice, List.of());
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public boolean processNext() {
        List<PendingEvent> events = jdbc.query("""
                SELECT id, event_type, aggregate_id, payload::text, created_by
                FROM business_outbox
                WHERE status = 0 AND available_at <= now()
                ORDER BY available_at, created_at, id
                FOR UPDATE SKIP LOCKED
                LIMIT 1
                """, (rs, rowNum) -> new PendingEvent(
                rs.getObject("id", UUID.class),
                rs.getString("event_type"),
                rs.getObject("aggregate_id", UUID.class),
                rs.getString("payload"),
                rs.getObject("created_by", UUID.class)));
        if (events.isEmpty()) {
            return false;
        }

        PendingEvent event = events.get(0);
        List<PendingEvent> delivery = new ArrayList<>(List.of(event));
        if (ChainNoticeService.EVENT_PLAN_SCHEDULED.equals(event.eventType())) {
            delivery.addAll(claimSameTypeSiblings(event));
        }
        try {
            for (PendingEvent one : delivery) {
                JsonNode payload = objectMapper.readTree(one.payload());
                for (BusinessOutboxDomainHandler handler : domainHandlers) {
                    if (handler.supports(one.eventType())) {
                        handler.handle(
                                one.id(), one.eventType(), one.aggregateId(),
                                payload, one.createdBy());
                    }
                }
            }
            if (delivery.size() == 1) {
                chainNotice.deliverOutboxEvent(
                        event.eventType(),
                        event.aggregateId(),
                        objectMapper.readTree(event.payload()));
            } else {
                List<ChainNoticeService.PlanScheduled> group = new ArrayList<>();
                for (PendingEvent sibling : delivery) {
                    group.add(new ChainNoticeService.PlanScheduled(
                            sibling.aggregateId(),
                            objectMapper.readTree(sibling.payload())
                                    .path("shortage").asBoolean(false)));
                }
                chainNotice.deliverPlanScheduledGroup(group);
            }
            for (PendingEvent one : delivery) {
                jdbc.update("""
                        UPDATE business_outbox
                        SET status = 1,
                            processed_at = now(),
                            last_error = NULL
                        WHERE id = ? AND status = 0
                        """, one.id());
            }
            return true;
        } catch (Exception error) {
            throw new OutboxDeliveryException(event.id(), error);
        }
    }

    /**
     * 排产事件按批合并投递：计划单与货品 1:1，批量审核同一订单会提交 N 个
     * {@code PRODUCTION_PLAN_SCHEDULED} 事件；认领首个事件时把其余同类待投递
     * 事件在同一事务里一并锁定，交给 {@link ChainNoticeService#deliverPlanScheduledGroup}
     * 按订单合成一条通知，避免销售按货品逐条收通知。SKIP LOCKED 保证多 worker
     * 安全；超出上限的事件留给下一轮继续合并。
     */
    private List<PendingEvent> claimSameTypeSiblings(PendingEvent claimed) {
        return jdbc.query("""
                SELECT id, event_type, aggregate_id, payload::text, created_by
                FROM business_outbox
                WHERE status = 0 AND available_at <= now()
                  AND event_type = ? AND id <> ?
                ORDER BY available_at, created_at, id
                FOR UPDATE SKIP LOCKED
                LIMIT 99
                """, (rs, rowNum) -> new PendingEvent(
                rs.getObject("id", UUID.class),
                rs.getString("event_type"),
                rs.getObject("aggregate_id", UUID.class),
                rs.getString("payload"),
                rs.getObject("created_by", UUID.class)),
                claimed.eventType(), claimed.id());
    }

    private record PendingEvent(
            UUID id,
            String eventType,
            UUID aggregateId,
            String payload,
            UUID createdBy) {
    }
}
