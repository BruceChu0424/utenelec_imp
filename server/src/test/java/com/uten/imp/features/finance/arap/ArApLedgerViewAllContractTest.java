package com.uten.imp.features.finance.arap;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;

import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * security-18：应收应付台账没有按人隔离的归属列，列表与详情都是全公司钱流数据，
 * 所以除了台账查看码还必须持「看全部钱流数据」。只持台账码的人列表、详情一律 403。
 */
class ArApLedgerViewAllContractTest {

    @Test
    void everyReadEndpointRequiresLedgerViewAndFinanceViewAll() {
        List<Method> reads = Arrays.stream(ArApLedgerController.class.getDeclaredMethods())
                .filter(method -> method.isAnnotationPresent(GetMapping.class))
                .toList();
        assertThat(reads).isNotEmpty();
        for (Method read : reads) {
            PreAuthorize guard = read.getAnnotation(PreAuthorize.class);
            assertThat(guard).as(read.getName()).isNotNull();
            assertThat(guard.value())
                    .as(read.getName())
                    .contains("hasAuthority('ar_ap_ledger:view')")
                    .contains("hasAuthority('finance:view:all')")
                    .doesNotContain(" or ");
        }
    }
}
