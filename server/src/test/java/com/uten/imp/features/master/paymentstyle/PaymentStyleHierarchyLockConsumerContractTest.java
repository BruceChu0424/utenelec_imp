package com.uten.imp.features.master.paymentstyle;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** 锁定 style 关联写入的加锁条件与顺序，防止后续重构重新引入 TOCTOU。 */
class PaymentStyleHierarchyLockConsumerContractTest {

    private static final Path SOURCE_ROOT = Path.of("src/main/java");
    private static final String ACCOUNT =
            "com/uten/imp/features/master/account/AccountService.java";
    private static final String LEGACY_ASSET =
            "com/uten/imp/features/finance/asset/FixedAssetService.java";
    private static final String LOCK = "PaymentStyleHierarchyLock.lock(em);";

    @Test
    void accountStyleWritesLockConditionallyBeforePersistenceOrRowLock()
            throws IOException {
        String source = source(ACCOUNT);
        assertConditionalLockBefore(
                source,
                "public AccountDetail create(",
                "if (req.getStyleId() != null || req.getStyleLegacyId() != null)",
                "repo.save(a);");
        assertConditionalLockBefore(
                source,
                "public AccountDetail update(",
                "if (targetActive || req.getStyleId() != null || req.getStyleLegacyId() != null)",
                "em.refresh(a, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);");
    }

    @Test
    void legacyAssetStyleWritesLockConditionallyBeforeNativeWriteSql()
            throws IOException {
        String source = source(LEGACY_ASSET);
        for (String signature : List.of(
                "public UUID createAsset(",
                "public void updateAsset(",
                "public UUID createDeferred(",
                "public void updateDeferred(")) {
            assertConditionalLockBefore(
                    source,
                    signature,
                    "if (uuid(b, \"expenseStyleId\") != null)",
                    "em.createNativeQuery(");
        }
    }

    private static void assertConditionalLockBefore(
            String source,
            String signature,
            String styleGuard,
            String writePath) {
        String body = methodBody(source, signature);
        int guardAt = body.indexOf(styleGuard);
        int lockAt = body.indexOf(LOCK);
        int writeAt = body.indexOf(writePath);
        assertTrue(guardAt >= 0, () -> signature + " must retain style-presence guard");
        assertTrue(lockAt > guardAt, () -> signature + " must lock inside the style guard");
        assertTrue(writeAt > lockAt, () -> signature + " must lock before " + writePath);
        assertEquals(1, occurrences(body, LOCK),
                () -> signature + " must have exactly one conditional hierarchy lock");

        int guardOpenBrace = body.indexOf('{', guardAt);
        int guardCloseBrace = matchingBrace(body, guardOpenBrace);
        assertTrue(lockAt > guardOpenBrace && lockAt < guardCloseBrace,
                () -> signature + " must skip the hierarchy lock when no style is supplied");
    }

    private static String methodBody(String source, String signature) {
        int signatureAt = source.indexOf(signature);
        assertTrue(signatureAt >= 0, () -> "missing method signature: " + signature);
        int openBrace = source.indexOf('{', signatureAt);
        int closeBrace = matchingBrace(source, openBrace);
        return source.substring(openBrace + 1, closeBrace);
    }

    private static int matchingBrace(String source, int openBrace) {
        assertTrue(openBrace >= 0, "missing opening brace");
        int depth = 0;
        for (int index = openBrace; index < source.length(); index++) {
            char character = source.charAt(index);
            if (character == '{') {
                depth++;
            } else if (character == '}' && --depth == 0) {
                return index;
            }
        }
        throw new AssertionError("unterminated block");
    }

    private static int occurrences(String source, String needle) {
        int count = 0;
        for (int at = source.indexOf(needle); at >= 0;
             at = source.indexOf(needle, at + needle.length())) {
            count++;
        }
        return count;
    }

    private static String source(String relativePath) throws IOException {
        return Files.readString(SOURCE_ROOT.resolve(relativePath));
    }
}
