package com.uten.imp.businesschain;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.HexFormat;
import java.util.Map;
import java.util.regex.Pattern;
import javax.sql.DataSource;
import org.springframework.jdbc.datasource.DelegatingDataSource;

/** Explicit1032 transport only. All results, writes, locks and owner guards still
 * execute on its untouched catalog. V1097's implicit historic version is1;
 * its later finished-allowance function did not exist and original approved Q
 * was the receipt amount authority. No Java quantity arithmetic is copied.
 * Frozen V798 SQL is from owning Git76ed3a78f2235a90be6e2f35e201338489ea1546.
 */
final class HistoricalSubcontract1032SqlTransport {
    private HistoricalSubcontract1032SqlTransport() { }
    private record SqlVersion(String label,String sql,boolean dropsMaterialVersion) { }
    private static final Map<String,SqlVersion> ORIGINAL_ENTITY_SQL=Map.ofEntries(
        Map.entry("b00c4dc817bfdf42f403da3cafac263693a530eb8e627826d3ffb735da827e0b", new SqlVersion("original V798 draw sets", """
                SELECT oi.id, facts.plan_item_id, facts.line_no, facts.goods_id, material.code, material.name,
                       facts.color_id, material_color.name, facts.unit_id, material_unit.name,
                       facts.bom_unit_qty, facts.sent_qty, facts.pending_qty,
                       facts.available_qty, facts.line_open, facts.needed_qty,
                       fn_subcontract_draw_sets(facts.usable_qty+facts.pending_qty
                           +CASE WHEN facts.line_open THEN facts.available_qty ELSE 0 END, facts.bom_unit_qty),
                       fn_subcontract_draw_sets(facts.usable_qty+facts.pending_qty, facts.bom_unit_qty),
                       NULL::numeric
                FROM subcontract_order_items oi
                CROSS JOIN LATERAL fn_subcontract_draw_facts(oi.id) facts
                LEFT JOIN goods material ON material.id = facts.goods_id
                LEFT JOIN colors material_color ON material_color.id = facts.color_id
                LEFT JOIN units material_unit ON material_unit.id = facts.unit_id
                WHERE oi.id IN (:factItemIds)
                ORDER BY oi.id, facts.line_no ASC NULLS LAST, facts.plan_item_id
                """, false)),
        Map.entry("4c905b3900449c99a10507906c5d3b6150274913aa770e9e7dfee8ae26035fd5", new SqlVersion("implicit pre1097 material version", """
                SELECT 1 FROM subcontract_receipt_items WHERE id=:id
                """, false)),
        Map.entry("56457863679d69c4b2bee2b4c6ca7e70b3a80fb5f5b536f4b80a1f442dda3b5e", new SqlVersion("original V798 material target", """
                WITH basis AS (
                    SELECT COALESCE(SUM(item.material_basis_qty), 0) AS received_basis
                    FROM subcontract_receipt_items item
                    JOIN subcontract_receipts receipt ON receipt.id = item.receipt_id
                     AND receipt.is_deleted = FALSE
                     AND (receipt.status = 1 OR receipt.id = :receiptId)
                    WHERE item.order_item_id = :orderItemId AND item.is_deleted = FALSE
                      AND item.material_basis_qty IS NOT NULL
                )
                SELECT plan_item.id,
                       COALESCE(goods.name, ''),
                       fn_subcontract_draw_f(basis.received_basis, plan_item.bom_unit_qty) AS target_qty,
                       COALESCE((
                           SELECT SUM(issue_item.consumed_qty)
                           FROM subcontract_material_issue_items issue_item
                           JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
                            AND issue.status = 1 AND issue.is_deleted = FALSE
                           WHERE issue_item.plan_item_id = plan_item.id
                             AND issue_item.is_deleted = FALSE
                       ), 0) AS consumed_qty
                FROM subcontract_material_plan_items plan_item
                JOIN goods ON goods.id = plan_item.goods_id
                CROSS JOIN basis
                WHERE plan_item.order_item_id = :orderItemId AND plan_item.is_deleted = FALSE
                ORDER BY plan_item.line_no ASC NULLS LAST, plan_item.id
                """, true)),
        Map.entry("0437124c3cdbb1bcb8a7dffed4ef2bed5507f187b3cadc1c99fdac1fcaa60197", new SqlVersion("original V798 consumption slice", """
                INSERT INTO subcontract_receipt_material_consumptions(receipt_item_id,issue_item_id,
                    qty_doc,qty_base,consumption_basis,created_by)
                SELECT :receipt,issue.id,:qty,:qty*issue.unit_rate,'FROZEN_BOM_ESTIMATE',:actor
                FROM subcontract_material_issue_items issue WHERE issue.id=:issue
                """, false))
    );
    private static final Map<String,String> ORIGINAL_JDBC_SQL=Map.of(
        "fb35f6004d16353eced9be6bf46222706b4cd83efede723431566b1150299ee6", """
                SELECT DISTINCT order_doc.bill_no AS order_bill_no,
                       c.goods_name_snapshot AS goods_name,
                       c.goods_code_snapshot AS goods_code,
                       unit.name AS unit_name,
                       oi.qty AS ordered_qty, current_return.delivered_qty,
                       GREATEST(oi.qty-current_return.delivered_qty
                           - fn_subcontract_settled_loss_qty(oi.id),0) AS shortfall_qty,
                       (c.status = 'WAITING_MORE') AS overdue_wait
                FROM subcontract_receipt_items receipt_item
                JOIN subcontract_order_items oi ON oi.id = receipt_item.order_item_id
                JOIN subcontract_orders order_doc ON order_doc.id = oi.order_id
                JOIN subcontract_short_delivery_cases c
                  ON c.order_item_id = receipt_item.order_item_id
                LEFT JOIN units unit ON unit.id = c.unit_id
                CROSS JOIN LATERAL (SELECT GREATEST(COALESCE(oi.received_qty, 0) - COALESCE(oi.returned_qty, 0)
                         - COALESCE((
                             SELECT SUM(rejection.failed_qty)
                             FROM procurement_iqc_rejection_cases rejection
                             WHERE rejection.receipt_type = 'SUBCONTRACT'
                               AND rejection.order_item_id = oi.id
                               AND rejection.is_deleted = FALSE
                               AND rejection.return_recorded_at IS NOT NULL
                               AND rejection.status IN ('RETURN_RECORDED', 'CREDIT_CONFIRMED',
                                                        'CLOSED_NO_CREDIT', 'FINANCE_EXCEPTION')
                         ), 0), 0) AS delivered_qty) current_return
                WHERE receipt_item.receipt_id = ?
                  AND order_doc.termination_case_id IS NULL
                  AND COALESCE(receipt_item.is_deleted, FALSE) = FALSE
                  AND current_return.delivered_qty < oi.qty
                  AND ((c.status='PENDING_OWNER' AND oi.allowed_loss_pct IS NOT NULL
                        AND current_return.delivered_qty < (oi.qty*(100-oi.allowed_loss_pct)*0.01))
                       OR (c.status='WAITING_MORE' AND c.expected_complete_by<CURRENT_DATE
                           AND (oi.allowed_loss_pct IS NULL OR current_return.delivered_qty
                                < (oi.qty*(100-oi.allowed_loss_pct)*0.01))))
                ORDER BY goods_name
                """,
        "2d75f6ea0af7572638a2d3dfbfbb731586ba4dbe5ae0919d90c0e509fcb316a0", """
                SELECT item.material_basis_qty IS NOT NULL
                   AND item.material_basis_qty*COALESCE(item.unit_rate,1)=?
                   AND EXISTS(SELECT 1 FROM subcontract_material_plan_items plan
                       WHERE plan.order_item_id=item.order_item_id AND plan.is_deleted=FALSE)
                   AND NOT EXISTS(SELECT 1 FROM subcontract_material_plan_items plan
                       WHERE plan.order_item_id=item.order_item_id AND plan.is_deleted=FALSE
                         AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions c
                             JOIN subcontract_material_issue_items issue ON issue.id=c.issue_item_id
                             WHERE c.receipt_item_id=item.id AND issue.plan_item_id=plan.id
                               AND c.reversal_of IS NULL AND c.qty_doc>0
                               AND NOT EXISTS(SELECT 1 FROM subcontract_receipt_material_consumptions reversed
                                   WHERE reversed.reversal_of=c.id)))
                FROM subcontract_receipt_items item WHERE item.id=?
                """);
    private static final Pattern NORMAL_LIMIT=Pattern.compile(
            "(?is)'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"|--[^\\r\\n]*|/\\*.*?\\*/|\\b(fn_subcontract_normal_receipt_limit|fn_subcontract_physical_receipt_capacity)\\(\\s*([a-z_][a-z0-9_]*\\.id|\\?)\\s*\\)");

    static DataSource dataSource(DataSource actual) {
        return new OriginalDataSource(actual);
    }

    private static final class OriginalDataSource extends DelegatingDataSource implements AutoCloseable {
        private final DataSource actual;
        OriginalDataSource(DataSource actual){super(actual);this.actual=actual;}
        @Override public Connection getConnection() throws SQLException {return connection(actual.getConnection());}
        @Override public Connection getConnection(String username,String password) throws SQLException {
            return connection(actual.getConnection(username,password));
        }
        @Override public void close() {
            if(actual instanceof AutoCloseable closeable) {
                try {closeable.close();}
                catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IllegalStateException(interrupted);}
                catch(Exception failure){throw new IllegalStateException(failure);}
            }
        }
    }

    private static Connection connection(Connection actual) {
        return (Connection)Proxy.newProxyInstance(Connection.class.getClassLoader(),new Class<?>[]{Connection.class},
                (proxy,method,args)->{
                    if(method.getDeclaringClass()==Object.class)return identity(proxy,method,args);
                    Object[] values=args;
                    if((method.getName().equals("prepareStatement")||method.getName().equals("prepareCall"))
                            &&args!=null&&args.length>0&&args[0] instanceof String sql) {
                        values=args.clone();values[0]=originalJdbcSql(sql);
                    }
                    Object result=invoke(actual,method,values);
                    return method.getName().equals("createStatement")?statement((Statement)result):result;
                });
    }

    private static Statement statement(Statement actual) {
        return (Statement)Proxy.newProxyInstance(Statement.class.getClassLoader(),new Class<?>[]{Statement.class},
                (proxy,method,args)->{
                    if(method.getDeclaringClass()==Object.class)return identity(proxy,method,args);
                    Object[] values=args;
                    if(args!=null&&args.length>0&&args[0] instanceof String sql
                            &&(method.getName().startsWith("execute")||method.getName().equals("addBatch"))) {
                        values=args.clone();values[0]=originalJdbcSql(sql);
                    }
                    return invoke(actual,method,values);
                });
    }

    /** The pre1097 approved receipt ceiling is the actual stored order Q.
     * Only a simple owner-table UUID reference is admitted; unknown future SQL
     * fails rather than acquiring an arbitrary compatibility default. */
    static String originalJdbcSql(String sql) {
        String original=ORIGINAL_JDBC_SQL.get(fingerprint(sql));
        if(original!=null)return original;
        if(!sql.contains("fn_subcontract_normal_receipt_limit")
                &&!sql.contains("fn_subcontract_physical_receipt_capacity"))return sql;
        var match=NORMAL_LIMIT.matcher(sql);var out=new StringBuffer();
        while(match.find()) {
            if(match.group(1)==null)continue;
            String replacement=match.group(1).equalsIgnoreCase("fn_subcontract_physical_receipt_capacity")
                    ?"fn_subcontract_returnable_qty("+match.group(2)+")"
                    :"(SELECT original1032.qty FROM public.subcontract_order_items original1032 WHERE original1032.id="+match.group(2)+" AND NOT original1032.is_deleted)";
            match.appendReplacement(out,java.util.regex.Matcher.quoteReplacement(replacement));
        }
        match.appendTail(out);
        // Unrecognized future calls remain real SQL and fail on the untouched
        // old catalog. Quoted identifiers/literals/comments stay byte-for-byte.
        return out.toString();
    }

    static EntityManager entityManager(EntityManager actual) {
        return (EntityManager)Proxy.newProxyInstance(EntityManager.class.getClassLoader(),new Class<?>[]{EntityManager.class},
                (proxy,method,args)->{
                    if(method.getDeclaringClass()==Object.class)return identity(proxy,method,args);
                    if(method.getName().equals("createNativeQuery")&&args!=null&&args.length==1&&args[0] instanceof String sql) {
                        SqlVersion selected=ORIGINAL_ENTITY_SQL.get(fingerprint(sql));
                        if(selected!=null)return query(actual.createNativeQuery(selected.sql()),selected);
                        if(sql.contains("material_consumption_version")
                                ||sql.contains("fn_subcontract_material_consumption_cohort_target")
                                ||sql.contains("fn_subcontract_actual_receipt_sets"))
                            throw new IllegalStateException("Unversioned original1032 subcontract material SQL");
                    }
                    return invoke(actual,method,args);
                });
    }

    private static Query query(Query actual,SqlVersion selected) {
        return (Query)Proxy.newProxyInstance(Query.class.getClassLoader(),new Class<?>[]{Query.class},
                (proxy,method,args)->{
                    if(method.getDeclaringClass()==Object.class)return identity(proxy,method,args);
                    if(selected.dropsMaterialVersion()&&method.getName().equals("setParameter")
                            &&args!=null&&args.length==2&&"materialVersion".equals(args[0])) {
                        if(!(args[1] instanceof Number version)||version.intValue()!=1)
                            throw new IllegalStateException(selected.label()+": original1032 cannot adopt a post1097 material cohort");
                        return proxy;
                    }
                    Object result=invoke(actual,method,args);
                    return result==actual?proxy:result;
                });
    }

    static String fingerprint(String sql) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(sql.strip().replaceAll("\\s+"," ").getBytes(StandardCharsets.UTF_8)));
        } catch(NoSuchAlgorithmException impossible) {throw new IllegalStateException(impossible);}
    }

    private static Object invoke(Object target,Method method,Object[] args)throws Throwable {
        try {return method.invoke(target,args);}
        catch(InvocationTargetException failure){throw failure.getCause();}
    }
    private static Object identity(Object proxy,Method method,Object[] args) {
        return switch(method.getName()) {
            case "toString"->"Original1032 versioned SQL transport";
            case "hashCode"->System.identityHashCode(proxy);
            case "equals"->proxy==args[0];
            default->throw new UnsupportedOperationException(method.getName());
        };
    }
}
