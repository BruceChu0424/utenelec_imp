package com.uten.imp.features.subcontract.kit;

import com.uten.imp.application.port.SubcontractChainNoticePort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * ADR-156「委外申请可下单」提醒的重算(随 ADR-143 的领料重算 outbox 投递一起跑, 原事务已提交)。
 *
 * <p>高水位 {@code subcontract_application_kit_notice_marks}: 申请明细此刻可下单量比上次提醒时多才提醒
 * (行动卡每个申请明细一张, 通知侧按实时可下单量重建); 少了只把水位降下来并 epoch+1, 不打扰人;
 * 降到 0(物料被别的单占走、已全部下单、申请关闭)撤卡。只锁水位行, 不锁任何业务单据。
 * 水位行按申请明细 id 一条语句插齐, 外键 KEY SHARE 与下单命令锁申请明细的顺序一致(都按 id)。
 */
@Service
@RequiredArgsConstructor
public class SubcontractApplicationKitRecheckService {

    private final JdbcTemplate jdbc;
    private final SubcontractKitService kit;
    private final SubcontractChainNoticePort chainNotice;

    /** 某种物料到货、被释放或被占用后: 用到它的委外申请明细全部重算。 */
    @Transactional
    public void recheckForMaterial(UUID goodsId, UUID colorId) {
        if (goodsId == null) {
            return;
        }
        recheck(kit.applicationItemsUsingMaterial(goodsId, colorId));
    }

    /** 指定委外申请明细重算(不存在、已关闭或已下完的按可下单 0 处理)。 */
    @Transactional
    public void recheck(Collection<UUID> applicationItemIds) {
        if (applicationItemIds == null || applicationItemIds.isEmpty()) {
            return;
        }
        List<UUID> ids = applicationItemIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) {
            return;
        }
        String idList = ids.stream().map(UUID::toString).collect(Collectors.joining(","));
        jdbc.update("""
                INSERT INTO subcontract_application_kit_notice_marks(application_item_id)
                SELECT item.id FROM subcontract_application_items item
                WHERE item.id = ANY(CAST(string_to_array(CAST(? AS text), ',') AS uuid[]))
                ORDER BY item.id
                ON CONFLICT (application_item_id) DO NOTHING
                """, idList);
        Map<UUID, BigDecimal> orderable = kit.orderableNow(ids);
        for (UUID applicationItemId : ids) {
            if (!orderable.containsKey(applicationItemId)) {
                continue;
            }
            BigDecimal now = orderable.get(applicationItemId).max(BigDecimal.ZERO);
            BigDecimal mark = jdbc.queryForObject("""
                    SELECT notified_orderable FROM subcontract_application_kit_notice_marks
                    WHERE application_item_id = ? FOR UPDATE
                    """, BigDecimal.class, applicationItemId);
            BigDecimal previous = mark == null ? BigDecimal.ZERO : mark;
            if (now.compareTo(previous) > 0) {
                chainNotice.notifySubcontractOrderKitReady(applicationItemId);
                jdbc.update("""
                        UPDATE subcontract_application_kit_notice_marks
                        SET notified_orderable = ?, updated_at = now()
                        WHERE application_item_id = ?
                        """, now, applicationItemId);
            } else if (now.compareTo(previous) < 0) {
                jdbc.update("""
                        UPDATE subcontract_application_kit_notice_marks
                        SET notified_orderable = ?, epoch = epoch + 1, updated_at = now()
                        WHERE application_item_id = ?
                        """, now, applicationItemId);
                if (now.signum() == 0) {
                    chainNotice.resolveSubcontractOrderKitReady(applicationItemId);
                }
            }
        }
    }
}
