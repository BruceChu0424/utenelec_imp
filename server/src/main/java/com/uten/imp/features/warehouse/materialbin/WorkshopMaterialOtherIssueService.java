package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Material;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.MaterialInfo;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Period;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Settings;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.OtherIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.OtherIssueView;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 车间内料仓的其它耗用 (ADR-131 §5.3): 试模、清机、报废料、其它。当场从内料仓其它出库,
 * 价值去外部, 不摊给产品; 记进本仓开着的那一期, 业务日期记真实日期。
 */
@Service
public class WorkshopMaterialOtherIssueService {

    private static final Set<String> REASONS = Set.of("TRIAL_MOULD", "PURGE", "SCRAP_MATERIAL", "OTHER");

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialStockGateway gateway;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialOtherIssueService(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
                                             WorkshopMaterialStockGateway gateway,
                                             WorkshopMaterialCommandLedger commands, WorkshopMaterialScope scope,
                                             SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.bins = bins;
        this.gateway = gateway;
        this.commands = commands;
        this.scope = scope;
        this.currentUser = currentUser;
    }

    @Transactional
    public OtherIssueView create(OtherIssueRequest request) {
        UUID workshop = request.workshopDepartmentId();
        if (workshop == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        scope.requireWorkshop(workshop);
        MaterialInfo material = bins.periodicMaterial(request.goodsId());
        bins.requireColor(request.colorId());
        BigDecimal qty = request.qty();
        if (qty == null || qty.signum() <= 0 || qty.stripTrailingZeros().scale() > MoneyPolicy.QUANTITY_SCALE) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "公斤数必须大于 0, 最多保留 4 位小数");
        }
        if (request.reason() == null || !REASONS.contains(request.reason())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择试模、清机、报废料或其它");
        }
        String reasonText = request.reasonText() == null || request.reasonText().isBlank()
                ? null : request.reasonText().strip();
        if ("OTHER".equals(request.reason()) && (reasonText == null || reasonText.length() < 2
                || reasonText.length() > 200)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "选\"其它\"时请写明用在哪里 (2 到 200 个字)");
        }
        BigDecimal kilograms = MoneyPolicy.quantity(qty);
        return commands.execute("OTHER_ISSUE", request.idempotencyKey(), request, OtherIssueView.class, () -> {
            Settings settings = bins.enabledSettingsForShare(workshop);
            LocalDate today = BusinessTime.today();
            if (settings.goLiveDate() != null && today.isBefore(settings.goLiveDate())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "整批领料从 " + settings.goLiveDate() + " 起启用, 这之前不能登记内料仓的耗用");
            }
            Period period = bins.openPeriod(settings.binWarehouseId());
            gateway.lockInventory(List.of(new Material(material.goodsId(), request.colorId())));
            UUID id = UUID.randomUUID();
            WorkshopMaterialGuards.guarded(() -> db.update("""
                    INSERT INTO workshop_material_other_issues(
                        id, bin_warehouse_id, workshop_department_id, goods_id, color_id, unit_id, qty, reason,
                        reason_text, period_id, business_date, created_by)
                    VALUES (:id, :bin, :workshop, :goods, CAST(:color AS uuid), :unit, :qty, :reason, :reasonText,
                            :period, :businessDate, :actor)
                    """, new MapSqlParameterSource()
                    .addValue("id", id)
                    .addValue("bin", settings.binWarehouseId())
                    .addValue("workshop", workshop)
                    .addValue("goods", material.goodsId())
                    .addValue("color", request.colorId() == null ? null : request.colorId().toString())
                    .addValue("unit", material.unitId())
                    .addValue("qty", kilograms)
                    .addValue("reason", request.reason())
                    .addValue("reasonText", reasonText)
                    .addValue("period", period.id())
                    .addValue("businessDate", today)
                    .addValue("actor", currentUser.requireId())));
            var posted = gateway.otherIssue(id, settings.binWarehouseId(), workshop, material.goodsId(),
                    request.colorId(), material.unitId(), kilograms, today, reasonLabel(request.reason(), reasonText));
            return new Outcome<>(id, view(id, posted.documentId(), posted.billNo()));
        });
    }

    private OtherIssueView view(UUID id, UUID documentId, String billNo) {
        Map<String, Object> row = db.queryForMap("""
                SELECT other.id, other.workshop_department_id, other.bin_warehouse_id, other.goods_id,
                       goods.name AS goods_name, other.color_id, other.qty, other.reason, other.reason_text,
                       other.period_id, period.period_no, other.business_date
                FROM workshop_material_other_issues other
                JOIN goods ON goods.id = other.goods_id
                JOIN workshop_material_periods period ON period.id = other.period_id
                WHERE other.id = :id
                """, Map.of("id", id));
        return new OtherIssueView(id, (UUID) row.get("workshop_department_id"), (UUID) row.get("bin_warehouse_id"),
                (UUID) row.get("goods_id"), (String) row.get("goods_name"), (UUID) row.get("color_id"),
                WorkshopMaterialBinSupport.decimal(row.get("qty")), (String) row.get("reason"),
                (String) row.get("reason_text"), (UUID) row.get("period_id"),
                WorkshopMaterialBinSupport.number(row.get("period_no")).intValue(),
                WorkshopMaterialBinSupport.date(row.get("business_date")), documentId, billNo);
    }

    private static String reasonLabel(String reason, String text) {
        String label = switch (reason) {
            case "TRIAL_MOULD" -> "试模";
            case "PURGE" -> "清机";
            case "SCRAP_MATERIAL" -> "报废料";
            default -> "其它";
        };
        return text == null ? "内料仓其它耗用: " + label : "内料仓其它耗用: " + label + " (" + text + ")";
    }
}
