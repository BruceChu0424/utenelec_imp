package com.uten.imp.common.util;

import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
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
    void invalidIdentityCannotBeUsedForDerivedFields() {
        assertThrows(
                IllegalArgumentException.class,
                () -> IdCardUtil.birthDate(withChecksum("11010519990230002")));
        assertThrows(
                IllegalArgumentException.class,
                () -> IdCardUtil.gender(withChecksum("11010519990230002")));
    }

    private static String withChecksum(String firstSeventeen) {
        int sum = 0;
        for (int index = 0; index < WEIGHTS.length; index++) {
            sum += (firstSeventeen.charAt(index) - '0') * WEIGHTS[index];
        }
        return firstSeventeen + CHECK[sum % 11];
    }
}
