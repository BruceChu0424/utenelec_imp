package com.uten.imp.common.util;

import com.uten.imp.common.time.BusinessTime;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class IdCardUtilTest {

    private static final int[] WEIGHTS =
            {7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2};
    private static final char[] CHECK =
            {'1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'};

    @Test
    void validatesAndDerivesFieldsFromAResidentIdentity() {
        String id = "11010519491231002X";

        assertTrue(IdCardUtil.isValid(id));
        assertNull(IdCardUtil.check(id));
        assertEquals(LocalDate.of(1949, 12, 31), IdCardUtil.birthDate(id));
        assertEquals("female", IdCardUtil.gender(id));
        assertEquals("002X", IdCardUtil.last4(id));
    }

    @Test
    void normalizesFullWidthDigitsAndLowercaseCheckDigit() {
        assertEquals(
                "11010519491231002X",
                IdCardUtil.normalize(" １１０１０５１９４９１２３１００２ｘ "));
        assertTrue(IdCardUtil.isValid("１１０１０５１９４９１２３１００２ｘ"));
    }

    @Test
    void rejectsChecksumValidButSemanticallyInvalidIdentityNumbers() {
        assertFalse(IdCardUtil.isValid(withChecksum("11010519990230002")));
        assertFalse(IdCardUtil.isValid(withChecksum("00000019900101001")));
        assertFalse(IdCardUtil.isValid(withChecksum("11010519900101000")));
        assertFalse(IdCardUtil.isValid(withChecksum("11010517990101001")));
    }

    @Test
    void invalidIdentityCannotBeUsedForDerivedFieldsAndSaysWhatIsWrong() {
        IllegalArgumentException birth = assertThrows(
                IllegalArgumentException.class,
                () -> IdCardUtil.birthDate(withChecksum("11010519990230002")));
        assertEquals("身份证号第7-14位不是有效的出生日期", birth.getMessage());
        IllegalArgumentException gender = assertThrows(
                IllegalArgumentException.class,
                () -> IdCardUtil.gender("110105194912310021"));
        assertEquals(IdCardUtil.check("110105194912310021").message(), gender.getMessage());
    }

    @Test
    void eachProblemHasItsOwnCodeAndPlainMessage() {
        String future = BusinessTime.today().plusDays(1).format(DateTimeFormatter.BASIC_ISO_DATE);
        assertProblem(null, "empty", "身份证号不能为空");
        assertProblem("   ", "empty", "身份证号不能为空");
        assertProblem("11010519491231002", "length:17", "身份证号应为18位，当前为17位");
        assertProblem("11010519491231002X1", "length:19", "身份证号应为18位，当前为19位");
        assertProblem("110105A9491231002X", "character:7",
                "身份证号第7位不是数字(只有第18位可以是X)");
        assertProblem("X10105194912310021", "character:1",
                "身份证号第1位不是数字(只有第18位可以是X)");
        assertProblem("11010519491231002Y", "character:18", "身份证号第18位只能是数字或X");
        assertProblem(withChecksum("11010519990230002"), "birth_date",
                "身份证号第7-14位不是有效的出生日期");
        assertProblem(withChecksum("11010517990101001"), "birth_too_early",
                "身份证号第7-14位的出生日期早于1800年");
        assertProblem(withChecksum("110105" + future + "001"), "birth_future",
                "身份证号第7-14位的出生日期晚于今天");
        assertProblem(withChecksum("00000019900101001"), "region_code",
                "身份证号前6位地区码不能全为0");
        assertProblem(withChecksum("11010519900101000"), "sequence_code",
                "身份证号第15-17位顺序码不能全为0");
        assertProblem("110105194912310021", "check_digit",
                "身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对");
    }

    @Test
    void reportsOnlyTheFirstProblemInTheFixedOrder() {
        // 长度先于字符：17 位里带字母也先报长度。
        assertEquals("length:17", IdCardUtil.check("1101051949123100X").code());
        // 前 17 位的第一个非数字先于第 18 位。
        assertEquals("character:3", IdCardUtil.check("11A105194912310Z2Y").code());
        // 出生日期先于地区码与顺序码。
        assertEquals("birth_date", IdCardUtil.check(withChecksum("00000019991301000")).code());
        // 地区码先于顺序码，顺序码先于校验码。
        assertEquals("region_code", IdCardUtil.check("000000199001010000").code());
        assertEquals("sequence_code", IdCardUtil.check("110105199001010000").code());
    }

    @Test
    void validityIsExactlyTheAbsenceOfAProblem() {
        for (String value : List.of(
                "11010519491231002X", "11010519491231002x", "110105194912310021",
                "1101051949123100", withChecksum("11010519990230002"), "", "abc")) {
            assertEquals(IdCardUtil.check(value) == null, IdCardUtil.isValid(value), value);
        }
    }

    @Test
    void storedCodeRebuildsTheSameMessageAndUnknownCodesAreRejected() {
        String future = BusinessTime.today().plusDays(1).format(DateTimeFormatter.BASIC_ISO_DATE);
        for (String value : List.of(
                "", "1", "11010519491231002", "110105A9491231002X", "11010519491231002Y",
                withChecksum("11010519990230002"), withChecksum("11010517990101001"),
                withChecksum("110105" + future + "001"), withChecksum("00000019900101001"),
                withChecksum("11010519900101000"), "110105194912310021")) {
            IdCardProblem problem = IdCardUtil.check(value);
            assertEquals(problem, IdCardProblem.fromCode(problem.code()), value);
        }
        for (String unknown : java.util.Arrays.asList(
                null, "", "valid", "unchecked", "length:", "length:18", "length:1234",
                "length:x", "character:0", "character:19", "character:-1", "invalid")) {
            assertNull(IdCardProblem.fromCode(unknown), String.valueOf(unknown));
        }
    }

    @Test
    void messagesNeverContainTheNumberItself() {
        for (String value : List.of(
                "11010519491231002", "110105A9491231002X", "110105194912310021",
                withChecksum("11010519990230002"), "430102200001011234")) {
            IdCardProblem problem = IdCardUtil.check(value);
            if (problem == null) {
                continue;
            }
            assertFalse(problem.message().contains(value.substring(value.length() - 4)), value);
            assertFalse(problem.message().contains(value.substring(0, 6)), value);
            assertFalse(problem.code().contains(value.substring(value.length() - 4)), value);
        }
    }

    private static void assertProblem(String value, String code, String message) {
        IdCardProblem problem = IdCardUtil.check(value);
        assertEquals(code, problem == null ? null : problem.code(), String.valueOf(value));
        assertEquals(message, problem.message(), String.valueOf(value));
        assertFalse(problem.message().contains("\uFF08"), "新增文案括号必须半角");
    }

    private static String withChecksum(String firstSeventeen) {
        int sum = 0;
        for (int index = 0; index < WEIGHTS.length; index++) {
            sum += (firstSeventeen.charAt(index) - '0') * WEIGHTS[index];
        }
        return firstSeventeen + CHECK[sum % 11];
    }
}
