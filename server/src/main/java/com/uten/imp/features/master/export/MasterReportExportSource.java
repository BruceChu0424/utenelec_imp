package com.uten.imp.features.master.export;

import com.uten.imp.application.port.MasterReportExportPort;
import com.uten.imp.application.port.ReportExportQuery;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.account.dto.AccountQueryFilter;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorQueryFilter;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.currency.dto.CurrencyQueryFilter;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.GoodsExportProjection;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.mould.MouldService;
import com.uten.imp.features.master.mould.dto.MouldQueryFilter;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.unit.dto.UnitQueryFilter;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.features.master.warehouse.dto.WarehouseQueryFilter;
import com.uten.imp.features.master.referencemethod.ReferenceMethodService;
import com.uten.imp.features.master.referencemethod.SettlementMethodAdminQueryFilter;
import jakarta.validation.Validator;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.util.Set;

/** Typed private-body adapter; business filters, names, precision and columns remain in their original services. */
@Component
@RequiredArgsConstructor
public class MasterReportExportSource implements MasterReportExportPort {
    private final GoodsService goods;
    private final ClientService clients;
    private final SupplierService suppliers;
    private final AccountService accounts;
    private final CurrencyService currencies;
    private final ColorService colors;
    private final UnitService units;
    private final MouldService moulds;
    private final WarehouseService warehouses;
    private final ReferenceMethodService references;
    private final ObjectMapper json;
    private final Validator validator;
    private final ExportLimitPort limits;

    public static String permission(String report) { return MasterReportExportPort.permission(report); }
    public static String projectionScope(String report) { return MasterReportExportPort.projectionScope(report); }
    public static String authorityDomain(String report) { return MasterReportExportPort.authorityDomain(report); }
    @Override
    public TableColumnProjection projection(ReportExportQuery request) {
        requireReport(request.report());
        return "goods".equals(request.report())
                ? GoodsExportProjection.forImportTemplate(request.columnProjection()) : request.columnProjection();
    }

    /** Call before persisting a job so unknown/credential fields are never stored as a private filter. */
    @Override
    public void validate(ReportExportQuery request) { filter(request); }

    @Override
    public ExportPayload read(ReportExportQuery request) {
        Object filter = filter(request);
        com.uten.imp.security.CurrentAuthorityGuard.requireAll(permission(request.report()));
        int maxRows = limits.exportMaxRows();
        return switch (request.report()) {
            case "goods" -> goods.export((GoodsQueryFilter)filter, request.sort(), request.order(), maxRows);
            case "client" -> clients.export((ClientQueryFilter)filter, request.sort(), request.order(), maxRows);
            case "supplier" -> suppliers.export((SupplierQueryFilter)filter, request.sort(), request.order(), maxRows);
            case "account" -> accounts.export((AccountQueryFilter)filter, request.sort(), request.order(), maxRows);
            case "currency" -> currencies.export((CurrencyQueryFilter)filter, request.sort(), request.order(), maxRows);
            case "color" -> colors.export((ColorQueryFilter)filter, maxRows);
            case "unit" -> units.export((UnitQueryFilter)filter, maxRows);
            case "mould" -> moulds.export((MouldQueryFilter)filter, maxRows);
            case "warehouse" -> warehouses.export((WarehouseQueryFilter)filter, maxRows);
            case "settlement_method" -> references.exportSettlementAdmin((SettlementMethodAdminQueryFilter)filter, maxRows);
            default -> throw invalid();
        };
    }

    private Object filter(ReportExportQuery request) {
        requireReport(request.report());
        if (!"master".equals(request.domain()) || !request.parameters().keySet().equals(Set.of("filter"))) throw invalid();
        String raw = request.parameters().get("filter");
        if (raw == null || raw.getBytes(StandardCharsets.UTF_8).length > 64 * 1024) throw invalid();
        try {
            JsonNode tree = json.readTree(raw);
            if (!(tree instanceof ObjectNode object)) throw invalid();
            rejectCredentials(tree);
            // Match the original ClientController default, while retaining an explicit false.
            if ("client".equals(request.report()) && !object.has("excludeLegacyFinanceStub"))
                object.put("excludeLegacyFinanceStub", true);
            Class<?> type = switch (request.report()) {
                case "goods" -> GoodsQueryFilter.class; case "client" -> ClientQueryFilter.class;
                case "supplier" -> SupplierQueryFilter.class; case "account" -> AccountQueryFilter.class;
                case "currency" -> CurrencyQueryFilter.class; case "color" -> ColorQueryFilter.class;
                case "unit" -> UnitQueryFilter.class; case "mould" -> MouldQueryFilter.class;
                case "warehouse" -> WarehouseQueryFilter.class;
                case "settlement_method" -> SettlementMethodAdminQueryFilter.class;
                default -> throw invalid();
            };
            Object value = json.readerFor(type).with(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
                    .readValue(json.treeAsTokens(tree));
            if (!validator.validate(value).isEmpty()) throw invalid();
            if (value instanceof ClientQueryFilter f)
                com.uten.imp.features.master.dto.ContactSensitiveFilter.requireBoundedReadValues(
                        f.keyword(), f.mobile(), f.phone(), f.phone2(), f.bankAccount());
            if (value instanceof SupplierQueryFilter f)
                com.uten.imp.features.master.dto.ContactSensitiveFilter.requireBoundedReadValues(
                        f.keyword(), f.mobile(), f.phone(), f.phone2(), f.bankAccount());
            return value;
        } catch (java.io.IOException | IllegalArgumentException failure) {
            // Neither parser excerpts nor the original private body may escape into task status/logs.
            throw invalid();
        }
    }
    private static void rejectCredentials(JsonNode node) {
        if (node.isObject()) {
            for (var field : node.properties()) {
                if ("password".equalsIgnoreCase(field.getKey())) throw invalid();
                rejectCredentials(field.getValue());
            }
        } else if (node.isArray()) node.forEach(MasterReportExportSource::rejectCredentials);
    }
    private static void requireReport(String report) { MasterReportExportPort.requireReport(report); }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "主档导出筛选参数无效"); }
}
