package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.UUID;

/** Immutable commercial snapshots shared by controlled editing and finance review. */
@Service
@RequiredArgsConstructor
public class SalesOrderRevisionService {
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final SecurityContextCurrentUser currentUser;

    @Transactional(propagation = Propagation.MANDATORY)
    public String snapshot(UUID orderId) {
        em.flush();
        return (String) em.createNativeQuery("""
                SELECT CAST(jsonb_build_object(
                    '订单信息', jsonb_build_object(
                        '客户', jsonb_build_object('id', o.client_id, 'label', concat_ws(' · ', client.code, client.name)),
                        '业务员', jsonb_build_object('id', o.seller_id, 'label', concat_ws(' · ', seller.full_name, seller.code)),
                        '币种', jsonb_build_object('id', o.currency_id, 'label', currency.name),
                        '单据日期', o.bill_date, '交货日期', o.deliver_date,
                        '结算方式', jsonb_build_object('id', o.settlement_method_id, 'label', settlement.name),
                        '合同号', o.contract_no, '签约地点', o.sign_addr,
                        '联系电话', o.link_phone, '收货地址', o.ship_addr,
                        '来源单号', o.source_doc_no,
                        '发运策略', o.shipment_policy, '备注', o.remark,
                        '税率', o.tax_rate, '原币合计', o.total_original),
                    '产品明细', COALESCE((
                        SELECT jsonb_object_agg(i.id::text, jsonb_build_object(
                            '行号', i.line_no,
                            '货品', jsonb_build_object('id', i.goods_id, 'label',
                                concat_ws(' · ', i.goods_code_snapshot, i.goods_name_snapshot)),
                            '颜色', jsonb_build_object('id', i.color_id, 'label', color.name),
                            '单位', jsonb_build_object('id', i.unit_id, 'label', unit.name),
                            '换算率', i.unit_rate, '数量', i.qty, '单价', i.price,
                            '折扣', i.discount, '原币金额', i.amount_original,
                            '客户编号', i.client_no, '客户型号', i.client_model,
                            '交货日期', i.deliver_date, '重量', i.weight,
                            '加工费', i.machining_price, '周长', i.circumference,
                            '来源单号', i.source_doc_no, '备注', i.remark))
                        FROM sales_order_items i
                        LEFT JOIN colors color ON color.id = i.color_id
                        LEFT JOIN units unit ON unit.id = i.unit_id
                        WHERE i.order_id = o.id AND NOT i.is_deleted
                    ), '{}'::jsonb)) AS text)
                FROM sales_orders o
                LEFT JOIN clients client ON client.id = o.client_id
                LEFT JOIN employees seller ON seller.id = o.seller_id
                LEFT JOIN currencies currency ON currency.id = o.currency_id
                LEFT JOIN settlement_methods settlement ON settlement.id = o.settlement_method_id
                WHERE o.id = :id
                """).setParameter("id", orderId).getSingleResult();
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public boolean record(UUID orderId, String before) {
        String after = snapshot(orderId);
        if (parse(before).equals(parse(after))) return false;
        em.createNativeQuery("""
                INSERT INTO sales_order_revision_logs(
                    order_id, before_snapshot, after_snapshot, changed_by_employee_id)
                VALUES (:id, CAST(:before AS jsonb), CAST(:after AS jsonb), :actor)
                """).setParameter("id", orderId).setParameter("before", before)
                .setParameter("after", after)
                .setParameter("actor", currentUser.requireEmployeeId()).executeUpdate();
        return true;
    }

    @Transactional(readOnly = true)
    public List<FieldChange> pendingChanges(UUID orderId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT CAST(log.before_snapshot AS text), CAST(log.after_snapshot AS text),
                       COALESCE(employee.full_name, ''), log.changed_at
                FROM sales_order_revision_logs log
                JOIN sales_orders o ON o.id = log.order_id
                LEFT JOIN employees employee ON employee.id = log.changed_by_employee_id
                WHERE log.order_id = :id
                  AND log.changed_at > COALESCE(o.finance_confirmed_at, to_timestamp(0))
                ORDER BY log.changed_at, log.id
                """).setParameter("id", orderId).getResultList();
        List<FieldChange> changes = new ArrayList<>();
        for (Object[] row : rows) {
            collectChanges("", parse((String) row[0]), parse((String) row[1]),
                    (String) row[2], com.uten.imp.common.util.NativeValueConverters
                            .toOffsetDateTime(row[3]), changes);
        }
        return List.copyOf(changes);
    }

    static void collectChanges(String path, JsonNode before, JsonNode after,
            String actor, OffsetDateTime at, List<FieldChange> changes) {
        if (before.equals(after)) return;
        if (before.isObject() && after.isObject() && !before.has("label") && !after.has("label")) {
            LinkedHashSet<String> fields = new LinkedHashSet<>();
            before.fieldNames().forEachRemaining(fields::add);
            after.fieldNames().forEachRemaining(fields::add);
            for (String field : fields) {
                String label = field;
                if ("产品明细".equals(path)) {
                    JsonNode line = after.has(field) ? after.path(field) : before.path(field);
                    label = "第 " + line.path("行号").asText("?") + " 行 "
                            + display(line.path("货品"));
                }
                collectChanges(path.isEmpty() ? label : path + " / " + label,
                        before.path(field), after.path(field), actor, at, changes);
            }
        } else {
            changes.add(new FieldChange(path, display(before), display(after), actor, at));
        }
    }

    private static String display(JsonNode node) {
        if (node.isMissingNode()) return "未设置";
        if (node.isNull()) return "未填写";
        if (node.isObject()) {
            if (node.has("label")) return display(node.path("label"));
            List<String> fields = new ArrayList<>();
            node.fields().forEachRemaining(field -> fields.add(field.getKey() + ": " + display(field.getValue())));
            return String.join("；", fields);
        }
        return node.asText();
    }

    private JsonNode parse(String json) {
        try { return mapper.readTree(json); }
        catch (java.io.IOException error) { throw new IllegalStateException("订单修改快照无效", error); }
    }

    public record FieldChange(String field, String beforeValue, String afterValue,
            String changedByName, OffsetDateTime changedAt) {}
}
