package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.lang.reflect.Array;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** The additive wire contract preserves editable text and the same money mask. */
class FinancialDecimalTextSerializationTest {
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();

    @ParameterizedTest(name = "{0}: exact text, legacy number, and null mask")
    @ValueSource(strings = {
            "receipt.dto.FinanceReceiptDetail", "receipt.dto.FinanceReceiptLineDto", "receipt.dto.FinanceReceiptListItem",
            "payment.dto.FinancePaymentDetail", "payment.dto.FinancePaymentLineDto", "payment.dto.FinancePaymentListItem",
            "expense.dto.FinanceExpenseDetail", "expense.dto.FinanceExpenseItemDto", "expense.dto.FinanceExpenseListItem",
            "other_income.dto.FinanceOtherIncomeDetail", "other_income.dto.FinanceOtherIncomeItemDto", "other_income.dto.FinanceOtherIncomeListItem",
            "bank_transfer.dto.FinanceBankTransferDetail", "bank_transfer.dto.FinanceBankTransferLineDto", "bank_transfer.dto.FinanceBankTransferListItem",
            "arap.dto.ArApLedgerDetail", "arap.dto.ArApLedgerListItem"
    })
    void additiveDecimalPropertiesNeverRoundOrBypassMaskedFields(String suffix) throws Exception {
        Class<?> type = Class.forName("com.uten.imp.features.finance." + suffix);
        Constructor<?> constructor = Arrays.stream(type.getDeclaredConstructors())
                .max(Comparator.comparingInt(Constructor::getParameterCount)).orElseThrow();
        constructor.setAccessible(true);
        Object[] args = Arrays.stream(constructor.getParameterTypes())
                .map(parameter -> parameter.isPrimitive() ? Array.get(Array.newInstance(parameter, 1), 0) : null)
                .toArray();
        Object dto = constructor.newInstance(args);
        List<Field> amounts = Arrays.stream(type.getDeclaredFields())
                .filter(field -> field.getType() == BigDecimal.class).toList();
        assertThat(amounts).isNotEmpty();
        for (String value : List.of("1234567890123.123456789012345678901234", "0.000000000000000000000007000001")) {
            for (Field field : amounts) {
                field.setAccessible(true);
                field.set(dto, new BigDecimal(value));
            }
            var json = mapper.readTree(mapper.writeValueAsString(dto));
            for (Field field : amounts) {
                assertThat(json.path(field.getName()).isNumber()).as(field.getName() + " legacy number").isTrue();
                assertThat(json.path(field.getName() + "Exact").isTextual()).as(field.getName() + " exact text").isTrue();
                assertThat(json.path(field.getName() + "Exact").textValue()).isEqualTo(value);
            }
        }
        for (Field field : amounts) field.set(dto, null);
        var masked = mapper.readTree(mapper.writeValueAsString(dto));
        for (Field field : amounts) {
            assertThat(masked.path(field.getName()).isNull()).as(field.getName() + " masked number").isTrue();
            assertThat(masked.path(field.getName() + "Exact").isNull()).as(field.getName() + " masked text").isTrue();
        }
    }
}
