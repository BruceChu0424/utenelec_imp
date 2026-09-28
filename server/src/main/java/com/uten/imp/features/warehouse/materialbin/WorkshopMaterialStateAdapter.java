package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WorkshopMaterialStatePort;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * 段的内料仓用料状态与开工门文案 (ADR-131 §5.4; 实现 {@link WorkshopMaterialStatePort})。
 *
 * <p>状态只读数据库函数 {@code fn_segment_bin_material_state}: 服务端开工门、数据库开工触发器、
 * 工作台读同一个口径。这里只把"待认料"与"车间没开启"翻成带产品名、料名、车间名的话。
 */
@Component
public class WorkshopMaterialStateAdapter implements WorkshopMaterialStatePort {

    private final NamedParameterJdbcTemplate db;

    public WorkshopMaterialStateAdapter(NamedParameterJdbcTemplate db) {
        this.db = db;
    }

    @Override
    @Transactional(readOnly = true)
    public String state(UUID segmentId) {
        if (segmentId == null) return NO_BIN;
        String state = db.queryForObject("SELECT fn_segment_bin_material_state(:segment)",
                Map.of("segment", segmentId), String.class);
        return state == null ? NO_BIN : state;
    }

    @Override
    @Transactional(readOnly = true)
    public Optional<String> startBlockMessage(UUID segmentId) {
        String state = state(segmentId);
        if (!NEED_CHOICE.equals(state) && !NEED_BIN.equals(state)) return Optional.empty();
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT product.name AS product_name, product.code AS product_code, workshop.name AS workshop_name,
                       (SELECT string_agg('「' || component.name || '」', '、' ORDER BY bom.sort_order, bom.id)
                        FROM goods_bom_items bom
                        JOIN goods component ON component.id = bom.component_goods_id
                         AND component.issue_method = 'PERIODIC'
                        WHERE bom.goods_id = segment.product_goods_id AND NOT bom.is_deleted) AS materials
                FROM production_execution_segments segment
                JOIN goods product ON product.id = segment.product_goods_id
                LEFT JOIN departments workshop ON workshop.id = segment.workshop_department_id
                WHERE segment.id = :segment
                """, Map.of("segment", segmentId));
        if (rows.isEmpty()) return Optional.empty();
        Map<String, Object> row = rows.getFirst();
        String product = label((String) row.get("product_name"), (String) row.get("product_code"));
        String workshop = row.get("workshop_name") == null ? "本车间" : (String) row.get("workshop_name");
        if (NEED_CHOICE.equals(state)) {
            return Optional.of("「" + product + "」还没选用车间内料仓里的哪种料, 请在开工确认表里认料后再开工");
        }
        String materials = row.get("materials") == null ? "整批领料的料" : (String) row.get("materials");
        return Optional.of("「" + product + "」用的" + materials + "要从车间内料仓领, 但「" + workshop
                + "」还没有开启整批领料。请找仓库开启, 或改派到已开启的车间");
    }

    private static String label(String name, String code) {
        if (name != null && !name.isBlank()) return name;
        return code == null ? "这个产品" : code;
    }
}
