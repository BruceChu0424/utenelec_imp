package com.uten.imp.features.stock.ledger;

import com.uten.imp.common.measure.WeightUnit;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.FacetBucket;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockWarehouseScope;
import com.uten.imp.features.stock.ledger.dto.StockLedgerPage;
import com.uten.imp.features.stock.ledger.dto.StockLedgerRow;
import com.uten.imp.features.stock.ledger.dto.StockLedgerSummary;
import com.uten.imp.features.stock.weight.WeightMath;
import org.springframework.data.domain.PageRequest;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 货品出入库流水 (存货明细账) 查询 (ADR-135 §7.1): GET /api/stock/goods/{goodsId}/ledger。
 *
 * <p>一次请求四条 SQL: 货品 (存在性/单位/是否按重量计)、当前页 (窗口倒推结存 + 单号/往来方/名称只对页内行关联)、
 * 汇总 + 显示行数 (一条聚合)、三个筛选桶 (一条语句)。SQL 见 {@link StockLedgerSql}。
 *
 * <p>脱敏: 金额按 {@link StockCostMasker} (goods:cost:view); 往来方名称按 {@link StockLedgerSourceAccess}
 * (能打开来源单据的权限)。按重量计的货品 (基本单位是重量单位) 结存重量 = 结存数量 × 换算系数, 不倒推。
 */
@Service
public class StockLedgerQueryService {

    /** 流水类型筛选里的伪类型: 只改重量的调整行。 */
    public static final String ADJUSTMENT_TYPE = "W";

    private final NamedParameterJdbcTemplate db;
    private final StockCostMasker costMasker;
    private final StockLedgerSourceAccess sourceAccess;

    public StockLedgerQueryService(NamedParameterJdbcTemplate db, StockCostMasker costMasker,
                                   StockLedgerSourceAccess sourceAccess) {
        this.db = db;
        this.costMasker = costMasker;
        this.sourceAccess = sourceAccess;
    }

    /**
     * @param goodsId                  货品
     * @param warehouseId              仓库 (含全部下级; null = 全部仓库)
     * @param colorId                  颜色
     * @param colorNull                只看无颜色 (colorId 为空时生效)
     * @param dateFrom                 起始业务日 (含)
     * @param dateTo                   截止业务日 (含, 按次日零点不含计)
     * @param movementTypes            逗号分隔的类型代码, 可含伪类型 W (重量调整)
     * @param direction                +1 / -1
     * @param includeWeightAdjustments 未按类型筛选时是否显示重量调整行 (默认否)
     */
    @Transactional(readOnly = true)
    public StockLedgerPage ledger(UUID goodsId, UUID warehouseId, UUID colorId, boolean colorNull,
                                  LocalDate dateFrom, LocalDate dateTo, String movementTypes, Short direction,
                                  boolean includeWeightAdjustments, int page, int size) {
        if (dateFrom != null && dateTo != null && dateFrom.isAfter(dateTo)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "起始日期不能晚于截止日期");
        }
        if (direction != null && direction != 1 && direction != -1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "方向只能是 1 (入) 或 -1 (出)");
        }
        TypeFilter types = parseTypes(movementTypes);
        GoodsHead goods = goods(goodsId);
        PageRequest paging = Pageables.of(page, size);
        StockLedgerQuery query = new StockLedgerQuery(goodsId,
                StockWarehouseScope.subtreeOf(db, warehouseId),
                colorId, colorId == null && colorNull,
                dateFrom == null ? null : BusinessTime.startOfDay(dateFrom),
                dateTo == null ? null : BusinessTime.startOfDay(dateTo.plusDays(1)),
                types.codes(), types.adjustments(), direction, includeWeightAdjustments,
                paging.getPageSize(), paging.getOffset());
        MapSqlParameterSource params = StockLedgerSql.params(query);

        boolean canViewCost = costMasker.canView();
        Set<String> authorities = sourceAccess.currentAuthorities();
        List<StockLedgerRow> items = db.query(StockLedgerSql.page(query), params,
                (rs, i) -> row(rs, goods, canViewCost, authorities));
        Totals totals = db.queryForObject(StockLedgerSql.summary(query), params, (rs, i) -> totals(rs));
        Map<String, List<FacetBucket>> facets = facets(query, params);

        long total = totals == null ? 0L : totals.displayRows();
        int totalPages = (int) ((total + paging.getPageSize() - 1) / paging.getPageSize());
        return new StockLedgerPage(items, paging.getPageNumber() + 1, paging.getPageSize(), total, totalPages,
                summary(totals, query, goods), facets);
    }

    // ------------------------------------------------------------------ rows

    /** 货品头: 基本单位名 + 按重量计时每基本单位千克数。 */
    record GoodsHead(UUID goodsId, String unitName, BigDecimal exactKgPerUnit) {
    }

    private GoodsHead goods(UUID goodsId) {
        List<GoodsHead> rows = db.query(StockLedgerSql.GOODS, new MapSqlParameterSource("goods", goodsId),
                (rs, i) -> new GoodsHead(goodsId, rs.getString("unit_name"),
                        WeightUnit.tryParse(rs.getString("mass_unit_code")).map(WeightUnit::kgPerUnit).orElse(null)));
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        }
        return rows.get(0);
    }

    static StockLedgerRow row(ResultSet rs, GoodsHead goods, boolean canViewCost, Set<String> authorities)
            throws SQLException {
        String rowKind = rs.getString("row_kind");
        boolean adjustment = "W".equals(rowKind);
        Short type = shortOrNull(rs, "movement_type");
        Short direction = shortOrNull(rs, "direction");
        String sourceDocType = rs.getString("source_doc_type");
        String docCode = rs.getString("source_doc_code");
        String adjustmentKind = rs.getString("adj_kind");
        String counterpartKind = rs.getString("counterpart_kind");
        boolean visible = counterpartKind == null
                || StockLedgerSourceAccess.canSeeCounterpart(sourceDocType, counterpartKind, authorities);
        BigDecimal balanceQty = rs.getBigDecimal("balance_qty_after");
        BigDecimal balanceWeight = goods.exactKgPerUnit() == null
                ? rs.getBigDecimal("balance_weight_after")
                : exactWeight(balanceQty, goods.exactKgPerUnit());
        return new StockLedgerRow(
                rowKind,
                rs.getObject("id", UUID.class),
                rs.getObject("transaction_date", OffsetDateTime.class),
                type,
                adjustment ? adjustmentLabel(adjustmentKind) : StockMovementTypeCatalog.label(type, direction, docCode),
                direction,
                sourceDocType,
                rs.getObject("source_doc_id", UUID.class),
                docCode,
                rs.getString("bill_no"),
                counterpartKind,
                visible ? rs.getString("counterpart_name") : null,
                !visible,
                rs.getObject("warehouse_id", UUID.class),
                rs.getString("warehouse_name"),
                rs.getObject("color_id", UUID.class),
                rs.getString("color_name"),
                adjustment ? null : rs.getBigDecimal("qty_signed"),
                goods.unitName(),
                rs.getBigDecimal("weight_signed"),
                rs.getString("weight_source"),
                adjustmentKind,
                balanceQty,
                balanceWeight,
                rs.getString("remark"),
                rs.getString("operator_name"),
                adjustment || !canViewCost ? null : rs.getBigDecimal("amount_local"),
                !canViewCost);
    }

    /** 重量调整行的类型名。 */
    static String adjustmentLabel(String kind) {
        if (kind == null) {
            return "重量调整";
        }
        return switch (kind) {
            case "ANCHOR" -> "重量起算";
            case "RESIDUAL" -> "重量尾差调整";
            case "COUNT" -> "盘点定重";
            case "MANUAL" -> "人工核重";
            case "REVERSAL" -> "撤销盘点重量";
            default -> "重量调整";
        };
    }

    /** 按重量计的货品: 重量 = 数量 × 换算系数 (4 位); 负数量不知道重量, 数量 0 重量 0。 */
    static BigDecimal exactWeight(BigDecimal qty, BigDecimal kgPerUnit) {
        if (qty == null) return null;
        if (qty.signum() < 0) return null;
        if (qty.signum() == 0) return BigDecimal.ZERO.setScale(WeightMath.SCALE);
        return WeightMath.times(qty, kgPerUnit);
    }

    // ------------------------------------------------------------------ summary

    /** 汇总 SQL 的原始结果。 */
    record Totals(BigDecimal qtyNow, BigDecimal weightNow, BigDecimal qtySinceFrom, BigDecimal weightSinceFrom,
                  boolean weightUnknownSinceFrom, BigDecimal qtySinceTo, BigDecimal weightSinceTo,
                  boolean weightUnknownSinceTo, long displayRows, BigDecimal inQty, BigDecimal outQty,
                  BigDecimal internalQty, BigDecimal inWeight, BigDecimal outWeight, long inWeightUnknown,
                  long outWeightUnknown, BigDecimal residualKg) {
    }

    private static Totals totals(ResultSet rs) throws SQLException {
        return new Totals(rs.getBigDecimal("qty_now"), rs.getBigDecimal("weight_now"),
                rs.getBigDecimal("qty_since_from"), rs.getBigDecimal("weight_since_from"),
                rs.getBoolean("weight_unknown_since_from"),
                rs.getBigDecimal("qty_since_to"), rs.getBigDecimal("weight_since_to"),
                rs.getBoolean("weight_unknown_since_to"),
                rs.getLong("display_rows"),
                rs.getBigDecimal("in_qty"), rs.getBigDecimal("out_qty"), rs.getBigDecimal("internal_qty"),
                rs.getBigDecimal("in_weight"), rs.getBigDecimal("out_weight"),
                rs.getLong("in_weight_unknown"), rs.getLong("out_weight_unknown"),
                rs.getBigDecimal("residual_kg"));
    }

    /**
     * 期初 = 锚点 − 起始日之后的变动; 期末 = 锚点 − 截止日之后的变动 (没给截止日即当前余额)。
     * 重量: 锚点未知或对应区间里有未知重量的行 → 未知; 按重量计的货品按数量折算。
     */
    static StockLedgerSummary summary(Totals t, StockLedgerQuery q, GoodsHead goods) {
        if (t == null) {
            return new StockLedgerSummary(BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                    BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, 0, 0,
                    BigDecimal.ZERO);
        }
        BigDecimal openingQty = t.qtyNow().subtract(t.qtySinceFrom());
        BigDecimal closingQty = q.toExclusive() == null ? t.qtyNow() : t.qtyNow().subtract(t.qtySinceTo());
        BigDecimal openingWeight = t.weightNow() == null || t.weightUnknownSinceFrom() ? null
                : t.weightNow().subtract(t.weightSinceFrom());
        BigDecimal closingWeight = q.toExclusive() == null ? t.weightNow()
                : t.weightNow() == null || t.weightUnknownSinceTo() ? null : t.weightNow().subtract(t.weightSinceTo());
        if (goods.exactKgPerUnit() != null) {
            openingWeight = exactWeight(openingQty, goods.exactKgPerUnit());
            closingWeight = exactWeight(closingQty, goods.exactKgPerUnit());
        }
        return new StockLedgerSummary(openingQty, closingQty, t.inQty(), t.outQty(), t.internalQty(),
                openingWeight, closingWeight, t.inWeight(), t.outWeight(), t.inWeightUnknown(),
                t.outWeightUnknown(), t.residualKg());
    }

    // ------------------------------------------------------------------ facets

    private Map<String, List<FacetBucket>> facets(StockLedgerQuery query, MapSqlParameterSource params) {
        Map<String, List<FacetBucket>> facets = new LinkedHashMap<>();
        facets.put("movementType", new ArrayList<>());
        facets.put("warehouse", new ArrayList<>());
        facets.put("color", new ArrayList<>());
        db.query(StockLedgerSql.facets(query), params, rs -> {
            long count = rs.getLong("n");
            if (count <= 0) {
                return;
            }
            String dimension = rs.getString("dim");
            String value = rs.getString("v");
            String label = switch (dimension) {
                case "movementType" -> ADJUSTMENT_TYPE.equals(value) ? "重量调整"
                        : StockMovementTypeCatalog.baseLabel(Short.valueOf(value));
                case "color" -> rs.getString("label") == null ? "无颜色" : rs.getString("label");
                default -> rs.getString("label");
            };
            facets.get(dimension).add(new FacetBucket(value, count, label));
        });
        facets.get("movementType").sort(java.util.Comparator.comparing(
                (FacetBucket b) -> ADJUSTMENT_TYPE.equals(b.value()) ? Integer.MAX_VALUE : Integer.parseInt(b.value())));
        facets.get("warehouse").sort(java.util.Comparator.comparingLong(FacetBucket::count).reversed()
                .thenComparing(b -> b.label() == null ? "" : b.label()));
        facets.get("color").sort(java.util.Comparator.comparingLong(FacetBucket::count).reversed()
                .thenComparing(b -> b.label() == null ? "" : b.label()));
        return facets;
    }

    // ------------------------------------------------------------------ parsing

    /** 类型筛选: 具体类型代码 + 是否点名重量调整 (W)。 */
    record TypeFilter(List<Short> codes, boolean adjustments) {
    }

    static TypeFilter parseTypes(String csv) {
        if (csv == null || csv.isBlank()) {
            return new TypeFilter(List.of(), false);
        }
        Set<Short> codes = new LinkedHashSet<>();
        boolean adjustments = false;
        for (String token : csv.split(",")) {
            String value = token.strip();
            if (value.isEmpty()) continue;
            if (ADJUSTMENT_TYPE.equals(value.toUpperCase(Locale.ROOT))) {
                adjustments = true;
                continue;
            }
            try {
                short code = Short.parseShort(value);
                if (code <= 0) throw new NumberFormatException(value);
                codes.add(code);
            } catch (NumberFormatException bad) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "不认识的出入库类型: " + value);
            }
        }
        return new TypeFilter(List.copyOf(codes), adjustments);
    }

    private static Short shortOrNull(ResultSet rs, String column) throws SQLException {
        short value = rs.getShort(column);
        return rs.wasNull() ? null : value;
    }
}
