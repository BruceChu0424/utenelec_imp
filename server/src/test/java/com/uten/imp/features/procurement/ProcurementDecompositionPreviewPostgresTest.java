package com.uten.imp.features.procurement;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.subcontract.application.SubcontractApplicationService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Actual service SELECTs and installed provenance/reservation functions on private PG.
 * The narrow schema intentionally tests source selection, not unrelated write workflows. */
@Testcontainers
class ProcurementDecompositionPreviewPostgresTest {
    @Container static final PostgreSQLContainer DATABASE = new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;
    static NamedParameterJdbcTemplate named;

    @BeforeAll static void schema() throws Exception {
        db = new JdbcTemplate(new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        named = new NamedParameterJdbcTemplate(db);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(db,
                "purchase_requests","purchase_request_items","purchase_orders","purchase_order_items","purchase_order_item_sources",
                "subcontract_applications","subcontract_application_items","subcontract_orders","subcontract_order_items","subcontract_order_item_sources",
                "procurement_order_approval_cases");
        for (Kind kind : Kind.values()) {
            db.execute("ALTER TABLE " + kind.items + " ADD FOREIGN KEY(" + kind.parent + ") REFERENCES " + kind.header + "(id)");
            db.execute("ALTER TABLE " + kind.orderItems + " ADD FOREIGN KEY(order_id) REFERENCES " + kind.orders + "(id), ADD FOREIGN KEY(" + kind.source + ") REFERENCES " + kind.items + "(id)");
            db.execute("ALTER TABLE " + kind.sources + " ADD FOREIGN KEY(order_item_id) REFERENCES " + kind.orderItems + "(id), ADD FOREIGN KEY(" + kind.source + ") REFERENCES " + kind.items + "(id)");
        }
        // Exact current catalog functions and real ownership FKs, never an unknown->native stub.
        com.uten.imp.support.MigratedProjectionSchema.installImportedDocumentPolicy(db,
                "purchase_requests","purchase_request_items","purchase_orders","purchase_order_items","purchase_order_item_sources",
                "subcontract_applications","subcontract_application_items","subcontract_orders","subcontract_order_items","subcontract_order_item_sources",
                "procurement_order_approval_cases");
        installFunction("V922__procurement_finance_approved_termination.sql",
                "CREATE OR REPLACE FUNCTION fn_procurement_order_latest_approval_status", "$function$;");
        installFunction("V923__procurement_termination_source_accounting.sql",
                "CREATE FUNCTION fn_procurement_order_reserves_source", "$$;");
    }

    static void installFunction(String file, String anchor, String delimiter) throws Exception {
        String sql = Files.readString(Path.of("src/main/resources/db/migration", file));
        int start = sql.indexOf(anchor);
        int end = start < 0 ? -1 : sql.indexOf(delimiter, start);
        assertThat(start).as("real migration function anchor").isNotNegative();
        assertThat(end).as("real migration function terminator").isGreaterThan(start);
        db.execute(sql.substring(start, end + delimiter.length()));
    }

    @AfterEach void clearRequest() { RequestContextHolder.resetRequestAttributes(); }

    @org.junit.jupiter.api.BeforeEach void clearOwnedProjectionRows() {
        // Real catalog UNIQUE keys now apply. Each parameterized invocation owns
        // its source identities instead of relying on duplicate legacy IDs.
        db.execute("TRUNCATE procurement_order_approval_cases,purchase_order_item_sources,purchase_order_items,purchase_orders,purchase_request_items,purchase_requests,subcontract_order_item_sources,subcontract_order_items,subcontract_orders,subcontract_application_items,subcontract_applications");
    }

    @ParameterizedTest
    @CsvSource({"PURCHASE,CURRENT", "PURCHASE,ALL", "PURCHASE,LEGACY",
            "SUBCONTRACT,CURRENT", "SUBCONTRACT,ALL", "SUBCONTRACT,LEGACY"})
    void actionSourceRemainsNativeForEveryHistoricalListScope(Kind kind, String scope) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setParameter("originScope", scope);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        UUID nativeItem = line(kind, null, null);
        UUID legacyItem = line(kind, null, 701);
        UUID parentLegacyItem = line(kind, 702, null);
        assertThat(preview(kind, List.of(nativeItem))).hasSize(1);
        for (UUID archived : List.of(legacyItem, parentLegacyItem)) {
            assertThat(db.queryForObject("SELECT fn_imported_business_document(?,?)", Boolean.class,
                    kind.items, archived)).isTrue();
            assertThatThrownBy(() -> preview(kind, List.of(archived))).isInstanceOfSatisfying(ApiException.class,
                    error -> assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
            assertThatThrownBy(() -> preview(kind, List.of(nativeItem, archived))).isInstanceOfSatisfying(ApiException.class,
                    error -> assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        }
        // Selection never changes the imported row's original lifecycle or quantities.
        assertThat(db.queryForObject("SELECT qty FROM " + kind.items + " WHERE id=?", BigDecimal.class, legacyItem))
                .isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT status FROM " + kind.header + " WHERE id=(SELECT " + kind.parent
                + " FROM " + kind.items + " WHERE id=?)", Integer.class, parentLegacyItem)).isEqualTo(1);
    }

    @Test void approvedReplacementDraftKeepsItsShareUntilNormalOrderStateOrQuantityChanges() {
        for (Kind kind : Kind.values()) {
            UUID item = line(kind, null, null), order = UUID.randomUUID(), orderItem = UUID.randomUUID();
            db.update("INSERT INTO " + kind.orders + "(id) VALUES(?)", order);
            db.update("INSERT INTO " + kind.orderItems + "(id,order_id," + kind.source + ",qty"
                    +(kind==Kind.PURCHASE?",gift_qty,quantity_semantics":"")+") VALUES(?,?,?,3"
                    +(kind==Kind.PURCHASE?",0,'CHARGED_PLUS_GIFT_V1'":"")+")",orderItem,order,item);
            db.update("INSERT INTO " + kind.sources + "(id,order_item_id," + kind.source + ",alloc_qty"
                    +(kind==Kind.PURCHASE?",allocated_gift_qty":"")+") VALUES(?,?,?,3"
                    +(kind==Kind.PURCHASE?",0":"")+")",UUID.randomUUID(),orderItem,item);
            assertPending(kind, item, "0"); // Merely saved, unsubmitted orders have no commitment.
            db.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,attempt,status,request_type,replacement_order_id) VALUES(?,?,?,1,'APPROVED','CLOSE_AND_REORDER',?)",
                    UUID.randomUUID(), kind.name(), UUID.randomUUID(), order);
            assertPending(kind, item, "3");
            db.update("UPDATE " + kind.sources + " SET alloc_qty=2 WHERE order_item_id=?", orderItem);
            assertPending(kind, item, "2");
            db.update("UPDATE " + kind.orders + " SET is_deleted=true WHERE id=?", order);
            assertPending(kind, item, "0");
            db.update("UPDATE " + kind.orders + " SET is_deleted=false,status=1 WHERE id=?", order);
            db.update("UPDATE " + kind.items + " SET ordered_qty=2 WHERE id=?", item);
            assertPending(kind, item, "0"); // Approved business quantity is counted as ordered, never pending twice.
        }
    }

    @Test void downstreamRunProvenanceDoesNotArchiveItsNativeSourceOrEraseExistingCommitment() {
        Kind kind=Kind.SUBCONTRACT;
        UUID item=line(kind,null,null),order=UUID.randomUUID(),orderItem=UUID.randomUUID();
        db.update("INSERT INTO subcontract_orders(id) VALUES(?)",order);
        db.update("INSERT INTO subcontract_order_items(id,order_id,application_item_id,qty) VALUES(?,?,?,3)",orderItem,order,item);
        db.update("INSERT INTO subcontract_order_item_sources(id,order_item_id,application_item_id,alloc_qty) VALUES(?,?,?,3)",UUID.randomUUID(),orderItem,item);
        db.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,attempt,status,request_type,replacement_order_id) VALUES(?,'SUBCONTRACT',?,1,'APPROVED','CLOSE_AND_REORDER',?)",UUID.randomUUID(),UUID.randomUUID(),order);
        assertPending(kind,item,"3");
        assertThatThrownBy(()->preview(kind,List.of(orderItem))).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThatThrownBy(()->preview(kind,List.of(item,orderItem))).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        // V624's real column exists on subcontract_orders. Requests/applications
        // and their items do not have a persisted run column; never invent one.
        db.update("UPDATE subcontract_orders SET legacy_import_run_id=? WHERE id=?",UUID.randomUUID(),order);
        assertThat(db.queryForObject("SELECT fn_imported_business_document('subcontract_orders',?)",Boolean.class,order)).isTrue();
        assertThat(db.queryForObject("SELECT fn_imported_business_document('subcontract_order_items',?)",Boolean.class,orderItem)).isTrue();
        assertThat(db.queryForObject("SELECT fn_imported_business_document('subcontract_application_items',?)",Boolean.class,item)).isFalse();
        // This query oracle models the provenance independently of write/import
        // protocol admission. Archive ancestry follows parents, not descendants.
        // V923 retires commitments only through a real termination decision;
        // V926 expressly preserves quantities. Read-only is not a quantity release.
        assertPending(kind,item,"3");
        // Same rejection as the native wrong-type control above. This proves
        // source-ID domains, not an archive rejection route for application rows.
        assertThatThrownBy(()->preview(kind,List.of(orderItem))).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThatThrownBy(()->preview(kind,List.of(item,orderItem))).isInstanceOfSatisfying(ApiException.class,
                error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(db.queryForObject("SELECT qty FROM subcontract_application_items WHERE id=?",BigDecimal.class,item)).isEqualByComparingTo("10");
        assertThat(db.queryForObject("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",BigDecimal.class,item)).isZero();
        assertThat(db.queryForObject("SELECT alloc_qty FROM subcontract_order_item_sources WHERE order_item_id=?",BigDecimal.class,orderItem)).isEqualByComparingTo("3");
    }

    static void assertPending(Kind kind, UUID item, String expected) {
        Object row = preview(kind, List.of(item)).getFirst();
        BigDecimal pending = row instanceof com.uten.imp.features.purchase.request.dto.DecompositionPreviewItem purchase
                ? purchase.pendingQty() : ((com.uten.imp.features.subcontract.application.dto.DecompositionPreviewItem) row).pendingQty();
        assertThat(pending).isEqualByComparingTo(expected);
    }

    static UUID line(Kind kind, Integer parentLegacy, Integer itemLegacy) {
        UUID header = UUID.randomUUID(), item = UUID.randomUUID();
        db.update("INSERT INTO " + kind.header + "(id,bill_no,legacy_id,status,is_closed) VALUES(?,?,?,1,false)",
                header, header.toString(), parentLegacy);
        db.update("INSERT INTO " + kind.items + "(id," + kind.parent + ",goods_id,unit_id,legacy_id,qty,unit_rate,ordered_qty"
                        +(kind==Kind.PURCHASE?",gift_qty,gift_ordered_qty,quantity_semantics":"")+") VALUES(?,?,?,?,?,10,1,0"
                        +(kind==Kind.PURCHASE?",0,0,'CHARGED_PLUS_GIFT_V1'":"")+")",
                item, header, UUID.randomUUID(), UUID.randomUUID(), itemLegacy);
        return item;
    }

    static List<?> preview(Kind kind, List<UUID> ids) {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);
            Query query = mock(Query.class);
            Map<String, Object> parameters = new LinkedHashMap<>();
            when(query.setParameter(anyString(), any())).thenAnswer(parameter -> {
                parameters.put(parameter.getArgument(0), parameter.getArgument(1));
                return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> named.query(sql, parameters, (rs, index) -> {
                Object[] values = new Object[rs.getMetaData().getColumnCount()];
                for (int column = 0; column < values.length; column++) values[column] = rs.getObject(column + 1);
                return values;
            }));
            return query;
        });
        if (kind == Kind.PURCHASE) {
            var service = new PurchaseRequestService(mock(com.uten.imp.features.purchase.request.PurchaseRequestRepository.class),
                    mock(com.uten.imp.features.purchase.request.PurchaseRequestItemRepository.class),
                    mock(com.uten.imp.security.TxSessionVars.class), mock(com.uten.imp.security.SecurityContextCurrentUser.class),
                    mock(com.uten.imp.common.util.EmployeeNameResolver.class), mock(com.uten.imp.common.docnumber.DocNumberService.class), em,
                    mock(com.uten.imp.common.integrity.ProductionSupplySourceGuard.class), mock(com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy.class),
                    mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class), mock(com.uten.imp.application.port.OrganizationReferencePort.class));
            return service.decompositionPreview(ids);
        }
        var service = new SubcontractApplicationService(mock(com.uten.imp.features.subcontract.application.SubcontractApplicationRepository.class),
                mock(com.uten.imp.features.subcontract.application.SubcontractApplicationItemRepository.class),
                mock(com.uten.imp.security.TxSessionVars.class), mock(com.uten.imp.common.docnumber.DocNumberService.class), em,
                mock(com.uten.imp.security.SecurityContextCurrentUser.class), mock(com.uten.imp.common.util.EmployeeNameResolver.class),
                mock(com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort.class), mock(com.uten.imp.common.integrity.ProductionSupplySourceGuard.class));
        return service.decompositionPreview(ids);
    }

    enum Kind {
        PURCHASE("purchase_requests", "purchase_request_items", "request_id", "purchase_orders", "purchase_order_items", "purchase_order_item_sources", "request_item_id"),
        SUBCONTRACT("subcontract_applications", "subcontract_application_items", "application_id", "subcontract_orders", "subcontract_order_items", "subcontract_order_item_sources", "application_item_id");
        final String header, items, parent, orders, orderItems, sources, source;
        Kind(String header, String items, String parent, String orders, String orderItems, String sources, String source) {
            this.header = header; this.items = items; this.parent = parent; this.orders = orders;
            this.orderItems = orderItems; this.sources = sources; this.source = source;
        }
    }
}
