package com.uten.imp.features.subcontract.report;

import com.uten.imp.common.finance.ProcurementDeliveryDifference;
import com.uten.imp.common.report.ReportQueryKit.FacetSpec;
import com.uten.imp.common.report.ReportQueryKit.WhereBuilder;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class SubcontractMaterialDeliveryDifferenceReportTest {
    @Test void bothMaterialReportsShareSourceOrderScopeFormulaAndSourceUnit() {
        for (boolean materialReturn : List.of(false, true)) {
            var service = service(true);
            load(service, materialReturn);
            var difference = service.columns.stream().filter(column -> column.key().equals("sourceOrderDifferenceQty")).findFirst().orElseThrow();
            assertThat(difference.unitKey()).isEqualTo("__sourceOrderDifferenceUnitName");
            assertThat(difference.totalLabel()).isNull();
            assertThat(service.select).contains("source_order_difference.qty AS \"sourceOrderDifferenceQty\"",
                    "source_order_difference.unit_name AS \"__sourceOrderDifferenceUnitName\"");
            assertThat(service.from).contains("source_item.id=i.order_item_id", "source_unit.id=source_item.unit_id",
                    "source_order.maker_id IN (:sourceDifferenceOwners)",
                    ProcurementDeliveryDifference.sql("source_item.qty", "source_item.received_qty", "source_item.returned_qty"));
            assertThat(service.where.build(null).params()).containsKey("sourceDifferenceOwners");
        }
    }

    @Test void missingSourceOrderPermissionKeepsMaterialRowsWithUnknownDifference() {
        for (boolean materialReturn : List.of(false, true)) {
            var service = service(false);
            load(service, materialReturn);
            assertThat(service.from).contains("LEFT JOIN LATERAL (SELECT NULL::numeric AS qty, NULL::text AS unit_name)")
                    .doesNotContain("FROM subcontract_order_items source_item");
        }
    }

    private static void load(CapturingService service, boolean materialReturn) {
        if (materialReturn) service.materialReturnDetail(null, null, null, null, null, null, null, Map.of(), 1, 20, "sourceOrderDifferenceQty", "asc");
        else service.materialIssueDetail(null, null, null, null, null, null, null, Map.of(), 1, 20, "sourceOrderDifferenceQty", "asc");
    }

    private static CapturingService service(boolean sourceReadable) {
        var service = new CapturingService();
        var access = mock(SubcontractDocumentAccessPolicy.class);
        when(access.hasAuthority("subcontract_order:view")).thenReturn(sourceReadable);
        when(access.nativeReadScope("source_order.maker_id", "sourceDifferenceOwners")).thenReturn(
                new DocumentAccessPolicy.NativeReadScope("source_order.maker_id IN (:sourceDifferenceOwners)", "sourceDifferenceOwners", Set.of(UUID.randomUUID())));
        ReflectionTestUtils.setField(service, "sourceOrderAccess", access);
        return service;
    }

    private static final class CapturingService extends SubcontractReportService {
        List<ReportColumn> columns;
        String select;
        String from;
        WhereBuilder where;
        CapturingService() { super(null, null); }
        @Override public ReportTableResponse execute(List<ReportColumn> columns, String select, String from,
                WhereBuilder where, String orderBy, List<FacetSpec> specs, Map<String, String> facets,
                int page, int size, String sort, String order) {
            this.columns = columns; this.select = select; this.from = from; this.where = where;
            return null;
        }
    }
}
