package com.uten.imp.businesschain;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocIssueBatchResponse;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** Real planning, requested quantities, approvals, inventory, reversals and frozen parent receipts. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.concurrency.verify-nested-footprint=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@Import(ProductionJdbcMeasurement.Configuration.class)
class StockDrawIssueBatchReceiptEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired ProductionDrawRequestService requests;

    @AfterEach void clear() {
        SecurityContextHolder.clearContext();
        ProductionJdbcMeasurement.end();
    }

    @Test void committedIntentIncludesEveryDocumentReasonAndWeightAndReplaysCanonicalOrder() {
        var setup = setup(2, true);
        UUID item = items(setup.documents().getFirst()).getFirst().getItemId();
        var command = command("frozen-intent-", setup.documents(), " 夜班发料 ");
        command.setWeights(List.of(new StockDocIssueBatchRequest.ItemWeight(item, new BigDecimal("2.50"), false)));
        assertEquals(2, stock.issueFullBatch(command).issuedCount());
        var replay = commandWithKey(command.getIdempotencyKey(),
                List.of(setup.documents().getLast(), setup.documents().getFirst(), setup.documents().getLast()), "夜班发料");
        replay.setWeights(List.of(new StockDocIssueBatchRequest.ItemWeight(item, new BigDecimal("2.5000"), null)));
        assertEquals(new StockDocIssueBatchResponse(0, 0, 2, true, List.of()), stock.issueFullBatch(replay));
        for (var changed : List.of(
                commandWithKey(command.getIdempotencyKey(), List.of(setup.documents().getFirst()), command.getReason()),
                commandWithKey(command.getIdempotencyKey(), List.of(UUID.randomUUID()), command.getReason()),
                commandWithKey(command.getIdempotencyKey(), command.getDocIds(), "另一备注"))) {
            changed.setWeights(command.getWeights());
            assertConflict(() -> stock.issueFullBatch(changed));
        }
        for (var changedWeight : List.of(new StockDocIssueBatchRequest.ItemWeight(item, new BigDecimal("2.6"), false),
                new StockDocIssueBatchRequest.ItemWeight(item, new BigDecimal("2.5"), true))) {
            var changed = commandWithKey(command.getIdempotencyKey(), command.getDocIds(), command.getReason());
            changed.setWeights(List.of(changedWeight));
            assertConflict(() -> stock.issueFullBatch(changed));
        }
        assertEquals(2, events(setup.documents()));
        assertEquals(1, receipts(command));
        assertThrows(DataAccessException.class, () -> db.update(
                "UPDATE stock_draw_issue_batches SET response_snapshot='{}'::jsonb WHERE idempotency_key=?", command.getIdempotencyKey()));
        assertThrows(DataAccessException.class, () -> db.update(
                "DELETE FROM stock_draw_issue_batches WHERE idempotency_key=?", command.getIdempotencyKey()));
    }

    @Test void cancellationCannotTurnEitherAnIssuedOrAllSkippedReceiptIntoNewInventoryWrites() {
        var setup = setup(1, true);
        UUID document = setup.documents().getFirst();
        var issued = command("cancel-frozen-", setup.documents(), "原批发料");
        assertEquals(1, stock.issueFullBatch(issued).issuedCount());
        var skipped = command("skip-frozen-", setup.documents(), null);
        assertEquals(new StockDocIssueBatchResponse(0, 1, 0, false, List.of()), stock.issueFullBatch(skipped));
        reverse(document);
        long movements = movementCount(document);
        assertEquals(new StockDocIssueBatchResponse(0, 0, 1, true, List.of()), stock.issueFullBatch(issued));
        assertEquals(new StockDocIssueBatchResponse(0, 1, 0, true, List.of()), stock.issueFullBatch(skipped));
        assertEquals(0, issuedQuantity(document).signum());
        assertEquals(movements, movementCount(document));
        assertEquals(1, stock.issueFullBatch(command("new-authorized-", setup.documents(), "核对后重新发料")).issuedCount());
    }

    @Test void aLaterWorkshopRequestNeedsANewBatchKeyEvenForTheSameDocument() {
        var setup = setup(1, false);
        UUID document = setup.documents().getFirst();
        submitRemaining(document, true);
        var command = command("half-request-", setup.documents(), null);
        assertEquals(1, stock.issueFullBatch(command).issuedCount());
        BigDecimal partial = issuedQuantity(document);
        assertEquals(0, new BigDecimal("15").compareTo(partial));
        submitRemaining(document, false);
        assertTrue(stock.issueFullBatch(command).replayed());
        assertEquals(0, partial.compareTo(issuedQuantity(document)), "later authorization must not alter an old receipt");
        assertEquals(1, stock.issueFullBatch(command("remaining-request-", setup.documents(), null)).issuedCount());
        assertEquals(0, new BigDecimal("30").compareTo(issuedQuantity(document)));
    }

    @Test void concurrentSameActorAndKeyCommitOneReceiptAndOneIssue() throws Exception {
        var setup = setup(1, true);
        var command = command("parallel-receipt-", setup.documents(), "同一次提交");
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        var start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var operation = (java.util.concurrent.Callable<StockDocIssueBatchResponse>) () -> {
                SecurityContextHolder.getContext().setAuthentication(authentication);
                try { start.await(); return stock.issueFullBatch(command); }
                finally { SecurityContextHolder.clearContext(); }
            };
            var first = pool.submit(operation);
            var second = pool.submit(operation);
            start.countDown();
            var a = first.get(60, TimeUnit.SECONDS);
            var b = second.get(60, TimeUnit.SECONDS);
            assertEquals(1, a.issuedCount() + b.issuedCount());
            assertEquals(1, a.replayedCount() + b.replayedCount());
        }
        assertEquals(1, events(setup.documents()));
        assertEquals(1, receipts(command));
    }

    @Test void differentActorsOwnIndependentKeysAndApprovedIssuerOnlyContractIsPreserved() {
        var setup = setup(2, true);
        UUID approved = setup.documents().getFirst(), draft = setup.documents().getLast();
        var firstLine = items(approved).getFirst();
        var partial = new StockDocIssueRequest();
        partial.setIdempotencyKey("prepare-approved-" + approved);
        partial.setLines(List.of(firstLine));
        stock.approveAndIssue(approved, partial);
        UUID issuer = warehouseIssuer(setup);
        var command = command("issuer-only-", List.of(approved), null);
        assertEquals(1, stock.issueFullBatch(command).issuedCount(), "approved documents require issue, not approve");
        assertTrue(stock.issueFullBatch(command).replayed());
        var draftCommand = command("issuer-draft-", List.of(draft), null);
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> stock.issueFullBatch(draftCommand)).getCode());
        assertEquals(0, receipts(draftCommand));
        setup.fixture().loginAs(setup.world().superAdminUserId());
        assertFalse(stock.issueFullBatch(command).replayed(), "same text key under another actor creates its own all-skipped receipt");
        assertEquals(2, receipts(command));
        loginIssuerOnly(issuer);
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",
                setup.world().departmentId(), issuer);
        assertEquals(ErrorCode.NOT_FOUND, assertThrows(ApiException.class, () -> stock.issueFullBatch(command)).getCode(),
                "an immutable receipt does not bypass current document readability");
        AuthUser actor = actor();
        authenticate(new AuthUser(actor.getId(), actor.getEmployeeId(), actor.getUsername(), Set.of(), false, true, false));
        assertThrows(AccessDeniedException.class, () -> stock.issueFullBatch(command), "entry issue permission remains mandatory on replay");
    }

    @Test void concurrentChangedDocumentSetsUnderOneActorKeyCannotBothIssue() throws Exception {
        var setup = setup(2, true);
        String key = "parallel-different-intent-" + UUID.randomUUID();
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        var start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var futures = setup.documents().stream().map(document -> pool.submit(() -> {
                SecurityContextHolder.getContext().setAuthentication(authentication);
                try {
                    start.await();
                    return stock.issueFullBatch(commandWithKey(key, List.of(document), null)).issuedCount();
                } catch (ApiException conflict) {
                    assertEquals(ErrorCode.CONFLICT, conflict.getCode());
                    return 0;
                } finally { SecurityContextHolder.clearContext(); }
            })).toList();
            start.countDown();
            assertEquals(1, futures.getFirst().get(60, TimeUnit.SECONDS) + futures.getLast().get(60, TimeUnit.SECONDS));
        }
        assertEquals(1, events(setup.documents()));
        assertEquals(1, db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches WHERE idempotency_key=?", Integer.class, key));
        assertEquals(1, setup.documents().stream().filter(document -> issuedQuantity(document).signum() == 0).count());
    }

    @Test void approvedAdminCommandPreservesNullableAuthenticationEmployeeWithoutRelaxingAccountSchema() {
        var setup = setup(1, true);
        UUID document = setup.documents().getFirst();
        var partial = new StockDocIssueRequest();
        partial.setIdempotencyKey("prepare-no-employee-" + document);
        partial.setLines(List.of(items(document).getFirst()));
        stock.approveAndIssue(document, partial);
        // The current users table requires employee_id. Exercise the nullable AuthUser/service
        // boundary with a real admin actor, without inventing a physical unbound account.
        AuthUser admin = actor();
        authenticate(new AuthUser(admin.getId(), null, admin.getUsername(), admin.getPermissions(), false, true, true));
        assertNull(actor().getEmployeeId());
        var command = command("admin-no-employee-", setup.documents(), null);
        assertEquals(1, stock.issueFullBatch(command).issuedCount());
        assertNull(db.queryForObject("SELECT actor_employee_id FROM stock_draw_issue_batches WHERE actor_user_id=? AND idempotency_key=?",
                UUID.class, admin.getId(), command.getIdempotencyKey()));
        assertTrue(stock.issueFullBatch(command).replayed());
    }

    @Test void aLateReceiptFailureRollsBackEveryApprovalPostingAndQuantityAndLeavesTheKeyReusable() {
        var setup = setup(2, true);
        var command = command("late-receipt-failure-", setup.documents(), null);
        db.execute("""
                CREATE FUNCTION test_reject_stock_batch_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'test failure after every issue and before receipt'; END; $$
                """);
        db.execute("CREATE TRIGGER test_reject_stock_batch_receipt BEFORE INSERT ON stock_draw_issue_batches FOR EACH ROW EXECUTE FUNCTION test_reject_stock_batch_receipt()");
        try {
            assertThrows(RuntimeException.class, () -> stock.issueFullBatch(command));
        } finally {
            db.execute("DROP TRIGGER test_reject_stock_batch_receipt ON stock_draw_issue_batches");
            db.execute("DROP FUNCTION test_reject_stock_batch_receipt()");
        }
        assertEquals(0, receipts(command));
        assertEquals(0, events(setup.documents()));
        for (UUID document : setup.documents()) {
            assertEquals(0, issuedQuantity(document).signum());
            assertEquals(0, movementCount(document));
            assertEquals(0, db.queryForObject("SELECT status FROM stock_documents WHERE id=?", Integer.class, document));
        }
        assertEquals(2, stock.issueFullBatch(command).issuedCount());
        assertEquals(1, receipts(command));
    }

    @Test void legacyChildFactsWithoutParentBlockTheWholeMixedBatchWithoutInventingHistoricalIntent() {
        var setup = setup(2, true);
        UUID legacy = setup.documents().getLast(), fresh = setup.documents().getFirst();
        var command = command("legacy-without-parent-", setup.documents(), "今天无法证明的原备注");
        String child = CanonicalFingerprint.sha256(List.of("STOCK-DRAW-ISSUE-BATCH-V1",
                "actor:" + actor().getId(), "batch:" + command.getIdempotencyKey(), "document:" + legacy));
        var oldSingle = new StockDocIssueRequest();
        oldSingle.setIdempotencyKey(child);
        oldSingle.setLines(items(legacy));
        oldSingle.setReason("真实旧逐单出库");
        stock.approveAndIssue(legacy, oldSingle);
        reverse(legacy);
        assertEquals(0, receipts(command));
        ApiException failure = assertThrows(ApiException.class, () -> stock.issueFullBatch(command));
        assertEquals(ErrorCode.CONFLICT, failure.getCode());
        assertTrue(failure.getMessage().contains("缺少完整批次回执"));
        assertEquals(0, receipts(command));
        assertEquals(1, events(setup.documents()));
        assertEquals(0, movementCount(fresh));
        assertEquals(0, issuedQuantity(legacy).signum());
        assertEquals(0, db.queryForObject("SELECT status FROM stock_documents WHERE id=?", Integer.class, fresh));
    }

    @Test void threeDocumentCommandAndReceiptReplayExposeComparableSqlShapes() throws Exception {
        boolean baseline = Boolean.getBoolean("uten.issue-batch.baseline");
        assertEquals(!baseline, java.util.Arrays.stream(StockDocService.class.getDeclaredFields())
                .anyMatch(field -> field.getName().equals("drawIssueBatchReceipts")), "execute the expected compiled Stock candidate");
        var setup = setup(3, true);
        var command = command("receipt-measure-", setup.documents(), "三单相同夹具");
        var sample = ProductionJdbcMeasurement.begin();
        try { assertEquals(3, stock.issueFullBatch(command).issuedCount()); }
        finally { ProductionJdbcMeasurement.end(); }
        assertEquals(1, sample.commits);
        assertEquals(0, sample.rollbacks);
        System.out.println("STOCK-BATCH-PARENT first=" + sample.result());
        var replay = ProductionJdbcMeasurement.begin();
        try { assertEquals(new StockDocIssueBatchResponse(0, 0, 3, true, List.of()), stock.issueFullBatch(command)); }
        finally { ProductionJdbcMeasurement.end(); }
        assertEquals(1, replay.commits);
        assertEquals(0, replay.rollbacks);
        System.out.println("STOCK-BATCH-PARENT replay=" + replay.result());
        if (!baseline) {
            long noticeScope = statementsWithLabel(sample,"workshop.arrival_notice_scope");
            assertEquals(setup.documents().size(),noticeScope,"one bounded arrival-capacity scope read per actually issued DRAW");
            assertEquals(0,statementsWithLabel(sample,"workshop.arrival_notice_watermark"),"FULL_KIT tasks do not change continuous-capacity watermarks");
            assertTrue(sample.logicalStatements-noticeScope <= 479,
                    "original work remains within 474 + 5 parent-command statements; arrival-capacity reads are counted separately");
            assertEquals(0,statementsWithLabel(replay,"workshop.arrival_notice_scope"),"receipt replay must not re-evaluate arrival capacity");
            assertEquals(0,statementsWithLabel(replay,"workshop.arrival_notice_watermark"),"receipt replay must not change arrival watermarks");
            assertTrue(replay.logicalStatements <= 12, "receipt replay must not rediscover or mutate the production graph");
        }
        String output = System.getProperty("uten.issue-batch.measurement-output");
        if (output != null) {
            byte[] bytecode;
            try (var input = StockDocService.class.getResourceAsStream("StockDocService.class")) {
                assertNotNull(input);
                bytecode = input.readAllBytes();
            }
            var digest = java.security.MessageDigest.getInstance("SHA-256");
            var result = java.util.Map.of("baseline", baseline,
                    "fixture", "3 DRAWs, each A10 requiring B20+E10, full workshop request, production diagnostic mode",
                    "stockSourceSha256", java.util.HexFormat.of().formatHex(digest.digest(java.nio.file.Files.readAllBytes(
                            java.nio.file.Path.of("src/main/java/com/uten/imp/features/stock/StockDocService.java")))),
                    "stockBytecodeSha256", java.util.HexFormat.of().formatHex(digest.digest(bytecode)),
                    "first", sample.result(), "replay", replay.result());
            new com.fasterxml.jackson.databind.ObjectMapper().writerWithDefaultPrettyPrinter()
                    .writeValue(java.nio.file.Path.of(output).toFile(), result);
        }
    }

    private static long statementsWithLabel(ProductionJdbcMeasurement.Sample sample,String label) {
        return sample.fingerprints.entrySet().stream()
                .filter(entry->label.equals(sample.labelsByFingerprint.get(entry.getKey())))
                .mapToLong(java.util.Map.Entry::getValue).sum();
    }

    private record Setup(FullChainEndToEndTest fixture, FullChainEndToEndTest.World world, List<UUID> documents) { }

    private Setup setup(int count, boolean requestAll) {
        var fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        var world = fixture.seedWorld("batch-parent-" + UUID.randomUUID());
        fixture.loginAs(world.superAdminUserId());
        for (UUID goods : List.of(world.goodsB(), world.goodsE())) {
            db.update("INSERT INTO stock_balances(warehouse_id,goods_id,color_id,qty) VALUES(?,?,NULL,1000)", world.warehouseId(), goods);
        }
        List<UUID> documents = new ArrayList<>();
        for (int i = 0; i < count; i++) {
            documents.add(ReflectionTestUtils.invokeMethod(fixture, "generateSingleWarehouseDraw", world, "parent-" + UUID.randomUUID()));
        }
        documents.sort(java.util.Comparator.comparing(UUID::toString));
        if (requestAll) fixture.requestWorkshopDraws("parent-" + UUID.randomUUID(), documents);
        return new Setup(fixture, world, List.copyOf(documents));
    }

    private void submitRemaining(UUID document, boolean half) {
        UUID segment = db.queryForObject("SELECT execution_segment_id FROM production_planning_package_documents WHERE document_id=? AND document_type='DRAW'", UUID.class, document);
        Long version = db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?", Long.class, segment);
        var selected = List.of(new ProductionDrawRequest.Item(segment, version));
        var preview = requests.preview(new ProductionDrawRequest.PreviewRequest(selected));
        var lines = preview.lines().stream().map(line -> new ProductionDrawRequest.Selection(line.drawItemId(),
                half ? line.qty().divide(BigDecimal.valueOf(2)) : line.qty())).toList();
        requests.submit(new ProductionDrawRequest.SubmitRequest(selected, "partial-authorized-" + UUID.randomUUID(), preview.fingerprint(), lines));
    }

    private UUID warehouseIssuer(Setup setup) {
        UUID user = setup.fixture().createUserWithPerms(setup.world(), "issuer-" + UUID.randomUUID(), "stock_doc:issue");
        UUID warehouseDepartment = db.queryForObject("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted", UUID.class);
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)", warehouseDepartment, user);
        // Grant only issue in the principal: department grants must not accidentally supply approval.
        loginIssuerOnly(user);
        return user;
    }

    private void loginIssuerOnly(UUID user) {
        var employee = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, user);
        authenticate(new AuthUser(user, employee, "issuer-test", Set.of("stock_doc:issue"), false, true, false));
    }

    private List<StockDocIssueRequest.Line> items(UUID document) {
        return db.query("SELECT id,qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted ORDER BY line_no,id", (rs, row) -> {
            var line = new StockDocIssueRequest.Line();
            line.setItemId(rs.getObject(1, UUID.class));
            line.setQty(rs.getBigDecimal(2));
            return line;
        }, document);
    }

    private void reverse(UUID document) {
        var request = new StockDocIssueRequest();
        request.setIdempotencyKey("reverse-receipt-" + UUID.randomUUID());
        request.setReason("核对后取消本次发料");
        request.setLines(items(document));
        stock.reverseIssue(document, request);
    }

    private StockDocIssueBatchRequest command(String prefix, List<UUID> documents, String reason) {
        return commandWithKey(prefix + UUID.randomUUID(), documents, reason);
    }

    private StockDocIssueBatchRequest commandWithKey(String key, List<UUID> documents, String reason) {
        var request = new StockDocIssueBatchRequest();
        request.setIdempotencyKey(key); request.setDocIds(documents); request.setReason(reason);
        return request;
    }

    private int receipts(StockDocIssueBatchRequest command) {
        return db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches WHERE idempotency_key=?", Integer.class, command.getIdempotencyKey());
    }

    private int events(List<UUID> documents) {
        return documents.stream().mapToInt(document -> db.queryForObject(
                "SELECT count(*) FROM production_material_stock_events WHERE stock_document_id=? AND event_type='ISSUE'", Integer.class, document)).sum();
    }

    private BigDecimal issuedQuantity(UUID document) {
        return db.queryForObject("SELECT COALESCE(SUM(issued_qty),0) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted", BigDecimal.class, document);
    }

    private long movementCount(UUID document) {
        return db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='STOCK_DOC' AND source_doc_id=?", Long.class, document);
    }

    private void assertConflict(org.junit.jupiter.api.function.Executable command) {
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class, command).getCode());
    }

    private AuthUser actor() { return (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal(); }
    private void authenticate(AuthUser user) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }
}
