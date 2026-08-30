package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class TopLevelWriteAuditContextArchitectureTest {

    private static final Path SOURCE_ROOT = Path.of("src/main/java");
    private static final String PREFERENCE =
            "com/uten/imp/features/preference/UserPreferenceService.java";
    private static final String NOTICE =
            "com/uten/imp/features/notice/NoticeService.java";
    private static final String SETTINGS =
            "com/uten/imp/features/admin/systemsetting/SystemSettingsService.java";
    private static final String SUGGESTION =
            "com/uten/imp/features/suggestion/SuggestionService.java";
    private static final String STOCK =
            "com/uten/imp/features/stock/StockBalanceAdjustmentService.java";
    private static final String ASSET =
            "com/uten/imp/features/finance/asset/FixedAssetService.java";
    private static final String GL =
            "com/uten/imp/features/finance/gl/GlPostingService.java";
    private static final String MRP =
            "com/uten/imp/features/production/mrp/MrpService.java";
    private static final String PLANNING_PACKAGE =
            "com/uten/imp/features/production/mrp/ProductionPlanningPackageService.java";
    private static final String EXECUTION_PACKAGE =
            "com/uten/imp/features/production/mrp/ProductionExecutionPackageCommandService.java";
    private static final String LOGIN_FAILURE =
            "com/uten/imp/features/auth/LoginFailureRecorder.java";
    private static final String PROFILE_REVIEW =
            "com/uten/imp/features/profileChange/ProfileChangeReviewService.java";
    private static final String LOGIN =
            "com/uten/imp/features/auth/LoginService.java";
    private static final String VISITOR_LOGIN =
            "com/uten/imp/features/visitor/VisitorAuthService.java";

    private static final List<String> TARGET_SERVICES = List.of(
            PREFERENCE,
            NOTICE,
            SETTINGS,
            SUGGESTION,
            STOCK,
            ASSET,
            GL,
            MRP,
            PLANNING_PACKAGE,
            EXECUTION_PACKAGE,
            LOGIN_FAILURE,
            PROFILE_REVIEW,
            LOGIN,
            VISITOR_LOGIN);

    @Test
    void targetedTopLevelWriteServicesInjectTransactionSessionVariables()
            throws IOException {
        for (String relativePath : TARGET_SERVICES) {
            assertTrue(
                    source(relativePath).contains("TxSessionVars tx"),
                    () -> relativePath + " must inject TxSessionVars");
        }
    }

    @Test
    void topLevelWriteMethodsBindBeforeTheirWritePath() throws IOException {
        assertBefore(PREFERENCE, "public void put(", "tx.bind();", "repo.save(");

        assertBefore(NOTICE, "public NoticeDto publish(",
                "tx.bind();", "noticeRepo.saveAndFlush(");
        assertBefore(NOTICE, "public void markRead(",
                "tx.bind();", "stateRepo.save(");
        assertBefore(NOTICE, "public void completeTodo(",
                "tx.bind();", "stateRepo.save(");
        assertBefore(NOTICE, "public void markAllRead(",
                "tx.bind();", "stateRepo.markAllVisibleRead(");
        assertBefore(NOTICE, "public int deleteForCurrentUser(",
                "tx.bind();", "stateRepo.saveAll(");

        assertBefore(SETTINGS, "public SystemSettingDto write(",
                "tx.bindActor(actorId, actorAccount);", "repo.save(");

        assertBefore(SUGGESTION, "public SuggestionDto submit(",
                "tx.bind();", "suggestionRepo.save(");
        assertBefore(SUGGESTION, "public SuggestionDto toggleLike(",
                "tx.bind();", "likeRepo.deleteById(");
        assertBefore(SUGGESTION, "public SuggestionDto reply(",
                "tx.bind();", "replyRepo.saveAndFlush(");

        assertBefore(STOCK, "public StockBalanceAdjustmentResult adjust(",
                "tx.bind();", "stockDocService.createAuthorizedBalanceAdjustment(");

        for (String signature : List.of(
                "public UUID createAsset(",
                "public void updateAsset(",
                "public UUID createDeferred(",
                "public void updateDeferred(")) {
            assertBefore(ASSET, signature, "tx.bind();", "em.createNativeQuery(");
        }
        for (String signature : List.of(
                "public int depreciate(",
                "public int amortize(")) {
            String body = methodBody(source(ASSET), signature);
            int bindingAt = body.indexOf("tx.bind();");
            int disabledAt = body.indexOf("Legacy destructive posting is disabled");
            assertTrue(bindingAt >= 0, () -> signature + " must call tx.bind();");
            assertTrue(disabledAt >= 0, () -> signature + " must remain fail-closed");
            assertTrue(bindingAt < disabledAt,
                    () -> signature + " must bind audit context before rejecting the legacy write");
            assertFalse(body.contains("em.createNativeQuery("),
                    () -> signature + " must not restore delete-and-rebuild posting");
        }

        assertBefore(GL, "public int generate(String period)",
                "tx.bind();", "generatePeriod(");
        assertBefore(GL, "public int generateAll()",
                "tx.bind();", "generatePeriod(");
        assertBefore(GL, "public UUID postExpenseDoc(",
                "tx.bind();", "removeAutoProjection(");
        assertBefore(GL, "public void removeExpenseDoc(",
                "tx.bind();", "removeAutoProjection(");

        assertBefore(MRP, "public MrpGenerateResult generate(UUID planId)",
                "tx.bind();", "generateInternal(");
        assertBefore(MRP,
                "public MrpGenerateResult generate(UUID planId, String strategy)",
                "tx.bind();", "generateInternal(");
        assertBefore(PLANNING_PACKAGE, "public PlanningPackageResult confirm(",
                "tx.bind();", "executionCommand.confirm(");
        assertBefore(PLANNING_PACKAGE,
                "public PlanningPackageLifecycleResult cancel(",
                "tx.bind();", "lifecycle(");
        assertBefore(PLANNING_PACKAGE,
                "public PlanningPackageLifecycleResult reverse(",
                "tx.bind();", "lifecycle(");
        assertBefore(EXECUTION_PACKAGE, "public PlanningPackageResult confirm(",
                "tx.bind();", "lockPlan(");

        assertBefore(LOGIN_FAILURE, "public void record(",
                "tx.bindActor(userId, loginAccount);",
                "userRepo.findByIdForUpdate(");
    }

    @Test
    void existingSensitiveFlowsBindAndAuditInTheCorrectOrder()
            throws IOException {
        assertBefore(PROFILE_REVIEW,
                "public ProfileChangeDto.BatchDetail review(",
                "tx.bindActor(reviewerId, reviewer.getLoginAccount());",
                "employeeRepo.save(");

        assertBefore(LOGIN, "public TokenResponse login(",
                "tx.bindActor(user.getId(), user.getLoginAccount());",
                "failureRecorder.record(");
        assertBefore(LOGIN, "public TokenResponse login(",
                "tx.bindActor(user.getId(), user.getLoginAccount());",
                "userRepo.save(");
        String successfulLoginAudit =
                "audit.logCommitted(user.getId(), user.getLoginAccount(),";
        assertBefore(LOGIN, "public TokenResponse login(",
                "TokenResponse response = tokenIssuer.issueTokens(user);",
                successfulLoginAudit);
        assertBefore(LOGIN, "public TokenResponse login(",
                "TokenResponse response = tokenIssuer.issueTokens(user);",
                "return response;");

        assertBefore(VISITOR_LOGIN,
                "public VisitorAuthDto.VisitorTokenResponse login(",
                "tx.bindActor(account.getId(), account.getVisitorNo());",
                "accountRepo.save(");
    }

    private static void assertBefore(
            String relativePath,
            String signature,
            String binding,
            String writePath) throws IOException {
        String body = methodBody(source(relativePath), signature);
        int bindingAt = body.indexOf(binding);
        int writeAt = body.indexOf(writePath);
        assertTrue(bindingAt >= 0, () -> signature + " must call " + binding);
        assertTrue(
                writeAt >= 0,
                () -> signature + " must retain expected write path " + writePath);
        assertTrue(
                bindingAt < writeAt,
                () -> signature + " must bind audit context before " + writePath);
    }

    private static String methodBody(String source, String signature) {
        int signatureAt = source.indexOf(signature);
        assertTrue(signatureAt >= 0, () -> "missing method signature: " + signature);
        int openBrace = source.indexOf('{', signatureAt);
        assertTrue(openBrace >= 0, () -> "missing method body: " + signature);
        int depth = 0;
        for (int index = openBrace; index < source.length(); index++) {
            char character = source.charAt(index);
            if (character == '{') {
                depth++;
            } else if (character == '}' && --depth == 0) {
                return source.substring(openBrace + 1, index);
            }
        }
        throw new AssertionError("unterminated method body: " + signature);
    }

    private static String source(String relativePath) throws IOException {
        return Files.readString(SOURCE_ROOT.resolve(relativePath));
    }
}
