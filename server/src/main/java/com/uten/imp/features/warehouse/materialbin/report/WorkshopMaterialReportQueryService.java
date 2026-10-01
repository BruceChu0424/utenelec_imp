package com.uten.imp.features.warehouse.materialbin.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPermissions;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.BinUsageRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.LedgerRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.MissingWeightRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.ProductUsageRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.WastePoint;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Array;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 车间内料仓用量报表 (ADR-131 §5.10): 内料仓用量表、产品用料表、耗用差异率趋势、缺单重清单、收发明细。
 *
 * <p>只读结算结果与流水视图, 不在这里重算理论或分摊。按对象范围过滤: 车间成员只看本车间的内料仓。
 * 金额与单价只给持"查看货品成本"权限的人 (其余人收到空值)。按期查询时列出期末日落在所选日期范围里的各期。
 */
@Service
public class WorkshopMaterialReportQueryService {

    /** 金额与单价的查看权限 (与货品成本同源)。 */
    static final String COST_VIEW = "goods:cost:view";

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialPermissions permissions;

    public WorkshopMaterialReportQueryService(NamedParameterJdbcTemplate db, WorkshopMaterialScope scope,
                                              WorkshopMaterialPermissions permissions) {
        this.db = db;
        this.scope = scope;
        this.permissions = permissions;
    }

    // ------------------------------------------------------------------ 内料仓用量表

    @Transactional(readOnly = true)
    public List<BinUsageRow> binUsage(UUID binId, LocalDate from, LocalDate to) {
        requireBin(binId);
        boolean amounts = permissions.has(COST_VIEW);
        return db.query(WorkshopMaterialCountBasisQuery.WITH + """
                SELECT report.period_id, report.period_no, report.start_date, report.end_date, report.period_status,
                       report.period_line_id, report.goods_id, goods.code AS goods_code, goods.name AS goods_name,
                       report.color_id, color.name AS color_name, unit.name AS unit_name, report.cost_basis,
                       report.opening_qty, report.transfer_in_qty, report.return_qty, report.other_issue_qty, report.adjustment_qty,
                       report.closing_qty, report.actual_qty, report.theory_qty, report.allocation_basis_qty,
                       report.diff_qty, report.waste_rate, report.outcome, report.flags, report.consumed_qty,
                       report.loss_qty, report.close_no, report.closed_at, report.current_value,
                       report.value_at_close,
                       CASE WHEN report.value_at_close IS NOT NULL AND abs(report.actual_qty) > 0
                            THEN round(report.value_at_close / abs(report.actual_qty), 4) END AS unit_cost
                """ + WorkshopMaterialCountBasisQuery.columns("report") + """
                FROM v_workshop_material_period_report report
                JOIN goods ON goods.id = report.goods_id
                LEFT JOIN colors color ON color.id = report.color_id
                LEFT JOIN units unit ON unit.id = report.unit_id
                """ + WorkshopMaterialCountBasisQuery.joins("report", "report.goods_id", "report.color_id") + """
                WHERE report.bin_warehouse_id = :bin
                  AND (CAST(:from AS date) IS NULL OR report.end_date >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL OR report.end_date <= CAST(:to AS date))
                ORDER BY report.period_no, goods.code, color.name NULLS FIRST
                """, range(binId, from, to), (rs, index) -> new BinUsageRow(
                uuid(rs, "period_id"), rs.getInt("period_no"), date(rs, "start_date"), date(rs, "end_date"),
                rs.getString("period_status"), uuid(rs, "period_line_id"), uuid(rs, "goods_id"),
                rs.getString("goods_code"), rs.getString("goods_name"), uuid(rs, "color_id"),
                rs.getString("color_name"), rs.getString("unit_name"), rs.getString("cost_basis"),
                rs.getBigDecimal("opening_qty"), rs.getBigDecimal("transfer_in_qty"), rs.getBigDecimal("return_qty"),
                rs.getBigDecimal("other_issue_qty"), rs.getBigDecimal("closing_qty"), rs.getBigDecimal("actual_qty"),
                rs.getBigDecimal("theory_qty"), rs.getBigDecimal("allocation_basis_qty"),
                rs.getBigDecimal("diff_qty"), rs.getBigDecimal("waste_rate"), rs.getString("outcome"),
                texts(rs, "flags"), rs.getBigDecimal("consumed_qty"), rs.getBigDecimal("loss_qty"),
                (Integer) rs.getObject("close_no"), rs.getObject("closed_at", OffsetDateTime.class),
                amounts ? rs.getBigDecimal("current_value") : null,
                amounts ? rs.getBigDecimal("value_at_close") : null,
                amounts ? rs.getBigDecimal("unit_cost") : null,
                rs.getString("opening_count_basis"), rs.getString("closing_count_basis"), rs.getBigDecimal("adjustment_qty")));
    }

    // ------------------------------------------------------------------ 产品用料表

    @Transactional(readOnly = true)
    public List<ProductUsageRow> productUsage(UUID binId, LocalDate from, LocalDate to) {
        requireBin(binId);
        boolean amounts = permissions.has(COST_VIEW);
        return db.query(WorkshopMaterialCountBasisQuery.WITH + """
                SELECT report.period_id, report.period_no, report.start_date, report.end_date,
                       report.close_material_id, report.cost_basis, report.material_goods_id,
                       material.code AS material_code, material.name AS material_name, report.material_color_id,
                       material_unit.name AS material_unit_name,
                       fn_weight_unit_kg_factor(material_profile.mass_unit_code) AS material_unit_kg_factor,
                       color.name AS material_color_name, report.product_goods_id, product.code AS product_code,
                       product.name AS product_name, report.output_qty, report.theory_qty, report.allocated_qty,
                       report.current_value, report.exclusive_period,
                       CASE WHEN report.output_qty > 0 AND report.theory_qty IS NOT NULL
                            THEN round(report.theory_qty / report.output_qty, 6) END AS unit_weight,
                       CASE WHEN report.output_qty > 0
                            THEN round(report.current_value / report.output_qty, 4) END AS unit_material_cost,
                       CASE WHEN report.exclusive_period AND report.output_qty > 0
                            THEN round(report.allocated_qty / report.output_qty, 6) END AS actual_per_unit
                """ + WorkshopMaterialCountBasisQuery.columns("report", "report.material_goods_id", "report.material_color_id") + """
                FROM v_workshop_material_product_report report
                JOIN goods material ON material.id = report.material_goods_id
                LEFT JOIN units material_unit ON material_unit.id = report.material_unit_id
                LEFT JOIN unit_measurement_profiles material_profile
                  ON material_profile.unit_id = report.material_unit_id AND material_profile.measurement_dimension = 'MASS'
                LEFT JOIN colors color ON color.id = report.material_color_id
                LEFT JOIN goods product ON product.id = report.product_goods_id
                """ + WorkshopMaterialCountBasisQuery.joins(
                        "report", "report.material_goods_id", "report.material_color_id") + """
                WHERE report.bin_warehouse_id = :bin
                  AND (CAST(:from AS date) IS NULL OR report.end_date >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL OR report.end_date <= CAST(:to AS date))
                ORDER BY report.period_no, material.code, product.code
                """, range(binId, from, to), (rs, index) -> new ProductUsageRow(
                uuid(rs, "period_id"), rs.getInt("period_no"), date(rs, "start_date"), date(rs, "end_date"),
                uuid(rs, "close_material_id"), rs.getString("cost_basis"), uuid(rs, "material_goods_id"),
                rs.getString("material_code"), rs.getString("material_name"), uuid(rs, "material_color_id"),
                rs.getString("material_color_name"), uuid(rs, "product_goods_id"), rs.getString("product_code"),
                rs.getString("product_name"), rs.getBigDecimal("output_qty"), rs.getBigDecimal("unit_weight"),
                rs.getBigDecimal("theory_qty"), rs.getBigDecimal("allocated_qty"),
                amounts ? rs.getBigDecimal("current_value") : null,
                amounts ? rs.getBigDecimal("unit_material_cost") : null,
                rs.getBoolean("exclusive_period"), rs.getBigDecimal("actual_per_unit"),
                rs.getString("opening_count_basis"), rs.getString("closing_count_basis"),
                rs.getString("material_unit_name"), rs.getBigDecimal("material_unit_kg_factor")));
    }

    // ------------------------------------------------------------------ 耗用差异率趋势 (接口名保留兼容)

    /** 按料、按期的耗用差异率 (只算主料); goodsId 为空 = 本仓全部主料。 */
    @Transactional(readOnly = true)
    public List<WastePoint> wasteTrend(UUID binId, UUID goodsId) {
        requireBin(binId);
        MapSqlParameterSource params = new MapSqlParameterSource("bin", binId);
        params.addValue("goods", goodsId, Types.OTHER);
        return db.query(WorkshopMaterialCountBasisQuery.WITH + """
                SELECT trend.period_id, trend.period_no, trend.start_date, trend.end_date, trend.goods_id,
                       goods.code AS goods_code, goods.name AS goods_name, trend.color_id, color.name AS color_name,
                       trend.waste_rate
                """ + WorkshopMaterialCountBasisQuery.columns("trend") + """
                FROM v_workshop_material_waste_trend trend
                JOIN goods ON goods.id = trend.goods_id
                LEFT JOIN colors color ON color.id = trend.color_id
                """ + WorkshopMaterialCountBasisQuery.joins("trend", "trend.goods_id", "trend.color_id") + """
                WHERE trend.bin_warehouse_id = :bin
                  AND (CAST(:goods AS uuid) IS NULL OR trend.goods_id = CAST(:goods AS uuid))
                ORDER BY goods.code, color.name NULLS FIRST, trend.period_no
                """, params, (rs, index) -> new WastePoint(uuid(rs, "period_id"), rs.getInt("period_no"),
                date(rs, "start_date"), date(rs, "end_date"), uuid(rs, "goods_id"), rs.getString("goods_code"),
                rs.getString("goods_name"), uuid(rs, "color_id"), rs.getString("color_name"),
                rs.getBigDecimal("waste_rate"), rs.getString("opening_count_basis"),
                rs.getString("closing_count_basis")));
    }

    // ------------------------------------------------------------------ 缺单重清单

    /** 本仓每个没结算的期间里有产量、BOM 没填单个重量的 (期, 产品, 料), 与拦结算同一口径。 */
    @Transactional(readOnly = true)
    public List<MissingWeightRow> missingWeights(UUID binId) {
        requireBin(binId);
        return db.query("""
                SELECT missing.period_id, period.period_no, period.start_date, period.end_date,
                       missing.product_goods_id, product.code AS product_code, product.name AS product_name,
                       missing.material_goods_id, material.code AS material_code, material.name AS material_name,
                       missing.material_color_id, color.name AS material_color_name, missing.output_qty
                FROM fn_workshop_material_missing_weights(:bin) missing
                JOIN workshop_material_periods period ON period.id = missing.period_id
                JOIN goods product ON product.id = missing.product_goods_id
                JOIN goods material ON material.id = missing.material_goods_id
                LEFT JOIN colors color ON color.id = missing.material_color_id
                ORDER BY period.period_no, product.code, material.code
                """, Map.of("bin", binId), (rs, index) -> new MissingWeightRow(uuid(rs, "period_id"),
                rs.getInt("period_no"), date(rs, "start_date"), date(rs, "end_date"), uuid(rs, "product_goods_id"),
                rs.getString("product_code"), rs.getString("product_name"), uuid(rs, "material_goods_id"),
                rs.getString("material_code"), rs.getString("material_name"), uuid(rs, "material_color_id"),
                rs.getString("material_color_name"), rs.getBigDecimal("output_qty")));
    }

    // ------------------------------------------------------------------ 收发明细

    /** 流水视图 (按业务日期倒序), 带库存单据号、领料单号、操作人; 日期范围按真实业务日期。 */
    @Transactional(readOnly = true)
    public PageResponse<LedgerRow> ledger(UUID binId, LocalDate from, LocalDate to, int page, int size) {
        requireBin(binId);
        var pageable = Pageables.of(page, size);
        MapSqlParameterSource params = range(binId, from, to)
                .addValue("limit", pageable.getPageSize()).addValue("offset", pageable.getOffset());
        Long total = db.queryForObject("""
                SELECT count(*) FROM v_workshop_material_bin_ledger ledger
                WHERE ledger.bin_warehouse_id = :bin
                  AND (CAST(:from AS date) IS NULL OR ledger.business_date >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL OR ledger.business_date <= CAST(:to AS date))
                """, params, Long.class);
        List<LedgerRow> rows = db.query("""
                SELECT ledger.source_row_id, ledger.source_kind, ledger.business_date, ledger.period_id,
                       period.period_no, ledger.goods_id, goods.code AS goods_code, goods.name AS goods_name,
                       ledger.color_id, color.name AS color_name, unit.name AS unit_name, ledger.signed_qty,
                       ledger.is_supplement,
                       COALESCE(requisition_doc.bill_no, other_doc.bill_no, approved_request.request_no) AS doc_no,
                       COALESCE(requisition.request_no, approved_request.request_no) AS request_no,
                       COALESCE(operator_employee.full_name, operator.login_account) AS operator_name,
                       COALESCE(posting.created_at, other.created_at, counted.created_at, adjustment.created_at) AS created_at,
                       CASE
                           WHEN adjustment.id IS NOT NULL THEN
                               CASE adjustment.kind WHEN 'OPENING' THEN '已审核上线期初: ' ELSE '已审核账面修正: ' END
                               || COALESCE(approved_request.reason,'')
                           WHEN ledger.source_kind IN ('ISSUE', 'RETURN') AND posting.is_supplement
                               THEN '上一期漏录补录: ' || posting.supplement_reason
                           WHEN ledger.source_kind = 'OTHER_ISSUE'
                               THEN CASE other.reason WHEN 'TRIAL_MOULD' THEN '试模' WHEN 'PURGE' THEN '清机'
                                                      WHEN 'SCRAP_MATERIAL' THEN '报废料'
                                                      ELSE COALESCE(other.reason_text, '其它') END
                           WHEN counted.id IS NOT NULL
                               THEN '盘点第 ' || count_doc.version || ' 版'
                                    || CASE counted.reason WHEN 'CORRECTION' THEN ' (更正)'
                                                           WHEN 'SUPPLEMENT' THEN ' (补录后自动更正)' ELSE '' END
                       END AS remark
                FROM v_workshop_material_bin_ledger ledger
                JOIN workshop_material_periods period ON period.id = ledger.period_id
                JOIN goods ON goods.id = ledger.goods_id
                LEFT JOIN colors color ON color.id = ledger.color_id
                LEFT JOIN units unit ON unit.id = goods.unit_id
                LEFT JOIN workshop_material_requisition_postings posting
                  ON ledger.source_kind IN ('ISSUE', 'RETURN') AND posting.id = ledger.source_row_id
                LEFT JOIN workshop_material_requisition_lines requisition_line ON requisition_line.id = posting.line_id
                LEFT JOIN workshop_material_requisitions requisition
                  ON requisition.id = requisition_line.requisition_id
                LEFT JOIN stock_document_items requisition_item ON requisition_item.id = posting.stock_document_item_id
                LEFT JOIN stock_documents requisition_doc ON requisition_doc.id = requisition_item.doc_id
                LEFT JOIN workshop_material_other_issues other
                  ON ledger.source_kind = 'OTHER_ISSUE' AND other.id = ledger.source_row_id
                LEFT JOIN stock_document_items other_item ON other_item.id = other.stock_document_item_id
                LEFT JOIN stock_documents other_doc ON other_doc.id = other_item.doc_id
                LEFT JOIN workshop_material_count_postings counted
                  ON ledger.source_kind IN ('CONSUME', 'CONSUME_REVERSE', 'GAIN', 'GAIN_REVERSE')
                 AND counted.id = ledger.source_row_id
                LEFT JOIN workshop_material_counts count_doc ON count_doc.id = counted.count_id
                LEFT JOIN workshop_material_count_adjustment_postings adjustment
                  ON ledger.source_kind IN ('OPENING','ADJUSTMENT') AND adjustment.id=ledger.source_row_id
                LEFT JOIN stock_count_requests approved_request ON approved_request.id=adjustment.request_id
                LEFT JOIN users operator
                  ON operator.id = COALESCE(posting.created_by, other.created_by, counted.created_by, adjustment.created_by)
                LEFT JOIN employees operator_employee ON operator_employee.id = operator.employee_id
                WHERE ledger.bin_warehouse_id = :bin
                  AND (CAST(:from AS date) IS NULL OR ledger.business_date >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL OR ledger.business_date <= CAST(:to AS date))
                ORDER BY ledger.business_date DESC, created_at DESC, ledger.source_row_id
                LIMIT :limit OFFSET :offset
                """, params, (rs, index) -> new LedgerRow(uuid(rs, "source_row_id"), rs.getString("source_kind"),
                date(rs, "business_date"), uuid(rs, "period_id"), rs.getInt("period_no"), uuid(rs, "goods_id"),
                rs.getString("goods_code"), rs.getString("goods_name"), uuid(rs, "color_id"),
                rs.getString("color_name"), rs.getString("unit_name"), rs.getBigDecimal("signed_qty"),
                rs.getBoolean("is_supplement"), rs.getString("doc_no"), rs.getString("request_no"),
                rs.getString("operator_name"), rs.getObject("created_at", OffsetDateTime.class),
                rs.getString("remark")));
        long count = total == null ? 0 : total;
        int pages = (int) ((count + pageable.getPageSize() - 1) / pageable.getPageSize());
        return new PageResponse<>(rows, pageable.getPageNumber() + 1, pageable.getPageSize(), count, pages);
    }

    // ------------------------------------------------------------------ 共用

    /** 内料仓必须是某个车间设置过的整批领料内料仓; 车间成员只看本车间。 */
    private void requireBin(UUID binId) {
        if (binId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择内料仓");
        List<UUID> workshops = db.queryForList("""
                SELECT settings.workshop_department_id
                FROM workshop_material_settings settings
                WHERE settings.periodic_bin_warehouse_id = :bin
                """, Map.of("bin", binId), UUID.class);
        if (workshops.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "这个仓库不是车间内料仓");
        scope.requireWorkshop(workshops.getFirst());
    }

    private static MapSqlParameterSource range(UUID binId, LocalDate from, LocalDate to) {
        MapSqlParameterSource params = new MapSqlParameterSource("bin", binId);
        params.addValue("from", from, Types.DATE);
        params.addValue("to", to, Types.DATE);
        return params;
    }

    private static UUID uuid(ResultSet rs, String column) throws SQLException {
        return rs.getObject(column, UUID.class);
    }

    private static LocalDate date(ResultSet rs, String column) throws SQLException {
        return rs.getObject(column, LocalDate.class);
    }

    private static List<String> texts(ResultSet rs, String column) throws SQLException {
        Array array = rs.getArray(column);
        if (array == null) return List.of();
        Object raw = array.getArray();
        if (!(raw instanceof String[] values)) return List.of();
        return Arrays.stream(values).toList();
    }
}
