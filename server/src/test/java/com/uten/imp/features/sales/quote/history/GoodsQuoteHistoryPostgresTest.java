package com.uten.imp.features.sales.quote.history;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Real PostgreSQL JSONB and pagination checks independent of mutable current quote items. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsQuoteHistoryPostgresTest {
    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static GoodsQuoteHistoryService service;

    @BeforeAll static void start() {
        DB.start();
        var source = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(source);
        service = new GoodsQuoteHistoryService(new NamedParameterJdbcTemplate(source));
        jdbc.execute("""
                CREATE TABLE clients(id uuid primary key, name text);
                CREATE TABLE employees(id uuid primary key, full_name text);
                CREATE TABLE sales_quotes(id uuid primary key, bill_no text, client_id uuid, seller_id uuid, maker_id uuid);
                CREATE TABLE sales_orders(id uuid primary key, source_quote_id uuid, client_id uuid, bill_no text, is_deleted boolean, created_at timestamptz default now());
                CREATE TABLE sales_quote_revision_logs(id uuid primary key, quote_id uuid, revision integer, action text, snapshot jsonb, created_at timestamptz default now());
                """);
    }

    @AfterAll static void stop() { DB.stop(); }

    @Test void historyUsesEverySubmittedSnapshotAndPreservesDeletedLinesAndOldCustomer() {
        UUID goods = UUID.randomUUID(), otherGoods = UUID.randomUUID();
        UUID quote = UUID.randomUUID(), order = UUID.randomUUID(), client = UUID.randomUUID();
        jdbc.update("INSERT INTO clients VALUES (?, '客户后来改名')", client);
        jdbc.update("INSERT INTO sales_quotes(id,bill_no,client_id) VALUES (?, 'XB-HISTORY', ?)", quote, client);
        jdbc.update("INSERT INTO sales_orders(id,source_quote_id,client_id,bill_no,is_deleted) VALUES (?,?,?,'XD-HISTORY',true)", order, quote, client);
        snapshot(quote, goods, 1, "SUBMIT", "1234567890.123456", client, "甲客户");
        snapshot(quote, goods, 2, "FINANCE_EDIT", "10.01", client, "甲客户");
        snapshot(quote, otherGoods, 3, "CONFIRM", "0", client, "乙客户");
        snapshot(quote, goods, 4, "WITHDRAW", "7", client, "乙客户");
        var result = service.list(goods, Integer.MAX_VALUE, 1);
        assertThat(result.getTotal()).isEqualTo(2);
        assertThat(result.getPage()).isEqualTo(2);
        assertThat(result.getItems()).singleElement().satisfies(row -> {
            assertThat(row.price()).isEqualTo("1234567890.123456");
            assertThat(row.clientName()).isEqualTo("甲客户");
            assertThat(row.sellerName()).isEqualTo("原销售");
            assertThat(row.orderId()).isEqualTo(order);
            assertThat(row.orderNo()).isEqualTo("XD-HISTORY");
        });
        assertThat(service.list(goods, -1, 1000).getSize()).isEqualTo(100);
        assertThat(service.list(UUID.randomUUID(), 1, 20).getItems()).isEmpty();
    }

    @Test void legacySnapshotWithoutPartyIdentityNeverBorrowsCurrentCustomerSellerOrOrder() {
        UUID goods = UUID.randomUUID(), quote = UUID.randomUUID(), client = UUID.randomUUID(), seller = UUID.randomUUID();
        jdbc.update("INSERT INTO clients VALUES (?, '当前客户乙')", client);
        jdbc.update("INSERT INTO employees VALUES (?, '当前销售乙')", seller);
        jdbc.update("INSERT INTO sales_quotes(id,bill_no,client_id,seller_id) VALUES (?, 'XB-LEGACY', ?, ?)", quote, client, seller);
        jdbc.update("INSERT INTO sales_orders(id,source_quote_id,client_id,bill_no,is_deleted) VALUES (?,?,?,'XD-CURRENT',false)", UUID.randomUUID(), quote, client);
        String json = """
                {"lines":[{"id":"%s","goodsId":"%s","qty":"2","price":"1234567890.123456","discount":"0.9","amount":"18"}]}
                """.formatted(UUID.randomUUID(), goods);
        jdbc.update("INSERT INTO sales_quote_revision_logs VALUES (?,?,1,'SUBMIT',?::jsonb,now())", UUID.randomUUID(), quote, json);
        assertThat(service.list(goods, 1, 20).getItems()).singleElement().satisfies(row -> {
            assertThat(row.clientName()).isEqualTo("历史未记录");
            assertThat(row.sellerName()).isEqualTo("历史未记录");
            assertThat(row.price()).isEqualTo("1234567890.123456");
            assertThat(row.orderId()).isNull();
            assertThat(row.orderNo()).isNull();
        });
    }

    @Test void anEarlierCustomerQuoteSnapshotCannotNavigateToTheLaterCustomersOrder() {
        UUID goods = UUID.randomUUID(), quote = UUID.randomUUID(), oldClient = UUID.randomUUID(), newClient = UUID.randomUUID();
        jdbc.update("INSERT INTO clients VALUES (?, '当前客户乙')", newClient);
        jdbc.update("INSERT INTO sales_quotes(id,bill_no,client_id) VALUES (?, 'XB-CHANGED-CUSTOMER', ?)", quote, newClient);
        jdbc.update("INSERT INTO sales_orders(id,source_quote_id,client_id,bill_no,is_deleted) VALUES (?,?,?,'XD-CUSTOMER-B',false)", UUID.randomUUID(), quote, newClient);
        snapshot(quote, goods, 1, "SUBMIT", "13.1", oldClient, "原客户甲");
        snapshot(quote, goods, 3, "CONFIRM", "16.3", newClient, "新客户乙");
        var rows = service.list(goods, 1, 20).getItems();
        assertThat(rows).hasSize(2);
        assertThat(rows.getFirst().clientName()).isEqualTo("新客户乙");
        assertThat(rows.getFirst().orderNo()).isEqualTo("XD-CUSTOMER-B");
        assertThat(rows.getLast().clientName()).isEqualTo("原客户甲");
        assertThat(rows.getLast().orderId()).isNull();
    }

    private void snapshot(UUID quote, UUID goods, int revision, String action, String price, UUID clientId, String client) {
        String json = """
                {"clientId":"%s","clientName":"%s","sellerName":"原销售","lines":[{"id":"%s","goodsId":"%s",
                "qty":"2.000","price":"%s","discount":"0.9","amount":"18.018"}]}
                """.formatted(clientId, client, UUID.randomUUID(), goods, price);
        jdbc.update("INSERT INTO sales_quote_revision_logs VALUES (?,?,?,?,?::jsonb,now()+?*interval '1 second')",
                UUID.randomUUID(), quote, revision, action, json, revision);
    }
}
