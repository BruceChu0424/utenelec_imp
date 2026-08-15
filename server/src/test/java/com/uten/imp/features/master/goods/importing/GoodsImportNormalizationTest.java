package com.uten.imp.features.master.goods.importing;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * 导入规范化规则回归（锁定决策：匹配键全角转半角 + 删全部空白）。
 *
 * <p>仅校验纯函数 {@link GoodsImportService#normKey}（全角字母/数字、全角空格、普通空格、
 * NBSP 均应被规范化），无需 DB；解析/校验/事务的真值留待运行期端到端验证。
 */
class GoodsImportNormalizationTest {

    @Test
    void normKey_stripsHalfWidthWhitespace() {
        assertEquals("HP0001", GoodsImportService.normKey(" HP 0001 "));
        assertEquals("HP0001", GoodsImportService.normKey("  HP   0001  "));
    }

    @Test
    void normKey_convertsFullWidthAlphanumericsToHalf() {
        assertEquals("HP0001", GoodsImportService.normKey("ＨＰ０００１"));
        assertEquals("AB12", GoodsImportService.normKey("ＡＢ１２"));
    }

    @Test
    void normKey_stripsFullWidthAndNbspSpaces() {
        // 全角空格 U+3000 + NBSP U+00A0
        assertEquals("HP0001", GoodsImportService.normKey("　HP　0001　"));
        assertEquals("HP0001", GoodsImportService.normKey("HP 0001"));
    }

    @Test
    void normKey_nullSafe() {
        assertEquals(null, GoodsImportService.normKey(null));
    }

    @Test
    void normCode_matchesCategoryNumberingUppercaseContract() {
        assertEquals("V6000001", GoodsImportService.normCode(" v6 000001 "));
    }
}
