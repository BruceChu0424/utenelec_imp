package com.uten.imp.features.sales.shipment;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesShipmentFinanceRateSqlContractTest {

    private static final Path SOURCE = Path.of(
            "src/main/java/com/uten/imp/features/sales/shipment/SalesShipmentService.java");
    private static final Path CONTROLLER = Path.of(
            "src/main/java/com/uten/imp/features/sales/shipment/SalesShipmentController.java");
    private static final Path QUERY_FILTER = Path.of(
            "src/main/java/com/uten/imp/features/sales/shipment/dto/ShipmentQueryFilter.java");
    private static final Path AR_AP_SERVICE = Path.of(
            "src/main/java/com/uten/imp/features/finance/arap/ArApLedgerServiceImpl.java");
    private static final Path TRANSACTION_GUARDS = Path.of(
            "src/main/resources/db/migration/V142__transactional_integrity_guards.sql");

    @Test
    void shippedPostingLocksAnActiveFinanceCurrencyRateBeforeStockMutation() throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();

        assertThat(source).contains("from currencies currency");
        assertThat(source).contains("currency.status = '使用'");
        assertThat(source).contains("currency.exchange_rate");
        assertThat(source).contains("for share");
        int approvalStart = source.indexOf("private shipmentdetail approvelocked");
        String approvalPath = source.substring(approvalStart,
                source.indexOf("public shipmentdetail reject", approvalStart));
        assertThat(approvalPath.indexOf("applyfinancepostingrate(s, items)"))
                .isLessThan(approvalPath.indexOf("stockservice.lockinventory"));
        assertThat(source).contains("item.setamountlocal(local)");
        assertThat(source).contains("shipment.setexchangerate(financerate)");
    }

    @Test
    void draftPersistenceIgnoresClientAuthoredLocalAmounts() throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();

        assertThat(source).contains("it.setamountlocal(null)");
        assertThat(source).contains("s.settotallocal(null)");
    }

    @Test
    void arSettlementMetadataUsesShippedBusinessDateAndAllCustomerFinanceGate() throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();

        assertThat(source).contains(
                "select client.default_settlement_method_id, client.price_style, client.tday",
                "client.status = '使用'",
                "client.is_deleted, false",
                "for share");
        assertThat(source).contains("settlement_role_cash.equals(method.systemrole())");
        assertThat(source).doesNotContain(
                "resolvepersistedlegacydefault",
                "clientpricestyle == 1",
                "pricestyle != null && pricestyle == 1");
        int approvalStart = source.indexOf("private shipmentdetail approvelocked");
        String approvalPath = source.substring(approvalStart,
                source.indexOf("public shipmentdetail reject", approvalStart));
        assertThat(approvalPath).contains(
                "lockclientsettlementsnapshot(s, recognitiondate)",
                "assertfinanceaudited(s)",
                "s.getid(), s.getbillno(), recognitiondate",
                "settlement.duedate()",
                "settlement.settlementstylelegacy()");
        assertThat(approvalPath).contains("s.gethandedoverat()");
        assertThat(approvalPath).doesNotContain(
                "s.getlastdate().tolocaldate()",
                "assertfinanceaudited(s, settlement.cashsettlement())");
    }

    @Test
    void financeReleaseLocksAClassifiedClientAndSeparatesFormalArFromPrepayment()
            throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ")
                .toLowerCase();
        int financeStart = source.indexOf(
                "public map<string, object> financeaudit(uuid id)");
        String financePath = source.substring(financeStart,
                source.indexOf("public map<string, object> financeauditreverse", financeStart));

        assertThat(financePath).contains(
                "loadclientsettlementdefaults(",
                "s.getclientid(), true)",
                "requireclassifiedsalespaymenttype(clientdefaults.salespaymenttype())");
        assertThat(source).contains(
                "client.sales_payment_type",
                "l.open_item_kind='receivable'",
                "l.source_doc_type<>'direct_receipt'",
                "l.open_item_kind='customer_prepayment'",
                "l.source_doc_type='direct_receipt'",
                "receipt.receipt_kind='customer_prepayment'",
                "l.currency_id=:currencyid",
                "map.entry(\"availableprepaymentoriginal\"",
                "map.entry(\"availableprepaymentlocal\"");
    }

    @Test
    void warehouseTaskListCanFilterTheDedicatedWorkStatus() throws Exception {
        String service = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ").toLowerCase();
        String controller = Files.readString(CONTROLLER, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ").toLowerCase();
        String filter = Files.readString(QUERY_FILTER, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ").toLowerCase();

        assertThat(filter).contains("string warehouseworkstatus");
        assertThat(controller).contains(
                "@requestparam(required = false) string warehouseworkstatus",
                "financeaudit, warehouseworkstatus, datefrom");
        assertThat(service).contains(
                "f.warehouseworkstatus() != null",
                "root.get(\"warehouseworkstatus\")",
                "f.warehouseworkstatus().trim() .touppercase");
    }

    @Test
    void shipmentRetryCannotCreateASecondActiveAr() throws Exception {
        String shipment = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ").toLowerCase();
        String arAp = Files.readString(AR_AP_SERVICE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ").toLowerCase();
        String guards = Files.readString(TRANSACTION_GUARDS, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ").toLowerCase();
        int approvalStart = shipment.indexOf("private shipmentdetail approvelocked");
        String approvalPath = shipment.substring(approvalStart,
                shipment.indexOf("public shipmentdetail reject", approvalStart));

        assertThat(shipment).contains(
                "lockmodetype.pessimistic_write",
                "仅草稿单据可审核");
        assertThat(approvalPath).contains(
                "if (!s.isarposted() && !customershipmentpolicy.free(s))",
                "arapservice.postarap",
                "s.setarposted(true)");
        assertThat(arAp).contains("findbysourceforupdate(req.sourcedocid(), req.sourcedoctype())");
        assertThat(guards).contains(
                "create unique index uq_arap_active_source",
                "on ar_ap_ledger (source_doc_type, source_doc_id)",
                "where source_doc_id is not null and is_deleted = false");
    }

    @Test
    void legacyPendingIsNeverAdvertisedAsEditableOrRejectable() throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ").toLowerCase();

        assertThat(source).contains("requirelegacyshipmentmutable(s)");
        for (String name : java.util.List.of("isrejectablestate", "iseditablestate")) {
            int start=source.indexOf("private boolean "+name+"(");
            String capability=source.substring(start,source.indexOf("}",start));
            assertThat(capability).contains("!\"legacy\".equals(shipment.getshipmentkind())","&& salesshipment.work_pending_pick.equals(")
                    .doesNotContain("|| salesshipment.work_legacy_pending");
        }
        assertThat(source).doesNotContain("approvable through the compatibility path");
    }

    @Test
    void financeReleaseAndRevokeAppendTheAuthoritySnapshotInTheSameService() throws Exception {
        String source = Files.readString(SOURCE, StandardCharsets.UTF_8)
                .replaceAll("\\s+", " ").toLowerCase();

        assertThat(source).contains(
                "appendfinancereleaseevent( s, \"released\"",
                "appendfinancereleaseevent( s, \"revoked\"",
                "insert into sales_shipment_finance_release_events",
                "shipment_total_original",
                ".setparameter(\"shipmenttotaloriginal\", shipment.gettotaloriginal())",
                "formal_ar_outstanding_local",
                "available_prepayment_original",
                "available_prepayment_local",
                "snapshotmoney(info, \"outstanding\")",
                "snapshotmoney(info, \"overfloor\")");
        assertThat(source.indexOf("appendfinancereleaseevent( s, \"released\""))
                .isLessThan(source.indexOf("chainnotice.notifyshipmentpendingpick"));
        assertThat(source.indexOf("appendfinancereleaseevent( s, \"revoked\""))
                .isLessThan(source.indexOf("chainnotice.notifyshipmentfinancereleaserevoked"));
    }
}
