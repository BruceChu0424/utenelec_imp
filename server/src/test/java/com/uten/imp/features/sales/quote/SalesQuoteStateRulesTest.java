package com.uten.imp.features.sales.quote;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** ADR-134 报价核价状态规则(纯函数): 分段、财务读范围、确认前阻断、修订号。 */
class SalesQuoteStateRulesTest {

    @Test
    void bucketsSeparateReturnedDraftsFromOrdinaryDrafts() {
        assertThat(SalesQuoteService.statusBucket(quote(0, null))).isEqualTo("DRAFT");
        SalesQuote returned = quote(0, "客户要改数量");
        assertThat(SalesQuoteService.statusBucket(returned)).isEqualTo("FINANCE_REJECTED");
        assertThat(SalesQuoteService.statusBucket(quote(2, null))).isEqualTo("PENDING_FINANCE");
        assertThat(SalesQuoteService.statusBucket(quote(1, null))).isEqualTo("APPROVED");
        assertThat(SalesQuoteService.statusBucket(quote(-1, null))).isEqualTo("REVERSED");
    }

    @Test
    void financeSeesSubmittedConfirmedAndCurrentlyReturnedQuotesOnly() {
        OffsetDateTime submitted = OffsetDateTime.now().minusHours(2);
        assertThat(SalesQuoteService.financeVisible(quote(2, null))).isTrue();
        SalesQuote confirmed = quote(1, null);
        confirmed.setFinanceConfirmedAt(submitted.plusHours(1));
        assertThat(SalesQuoteService.financeVisible(confirmed)).as("财务确认过的已核价").isTrue();
        assertThat(SalesQuoteService.financeVisible(quote(1, null)))
                .as("旧流程销售自审的已审报价(没有财务确认时间)不在财务读范围").isFalse();
        assertThat(SalesQuoteService.financeVisible(quote(-1, null))).isFalse();
        assertThat(SalesQuoteService.financeVisible(quote(0, null))).as("从没提交过的草稿").isFalse();

        SalesQuote returned = quote(0, "价格需销售与客户确认");
        returned.setSubmittedAt(submitted);
        returned.setFinanceReturnedAt(submitted.plusMinutes(30));
        assertThat(SalesQuoteService.financeVisible(returned)).as("本轮被财务退回").isTrue();

        SalesQuote withdrawn = quote(0, null);
        withdrawn.setSubmittedAt(submitted);
        assertThat(SalesQuoteService.financeVisible(withdrawn)).as("提交后销售撤回").isFalse();

        SalesQuote deleted = quote(2, null);
        deleted.setDeleted(true);
        assertThat(SalesQuoteService.financeVisible(deleted)).isFalse();
    }

    @Test
    void confirmIsBlockedByMissingPriceAndUnexplainedZeroPrice() {
        assertThat(SalesQuoteFinanceService.blockingReason(null, "MASTER", null)).contains("还没有单价");
        assertThat(SalesQuoteFinanceService.blockingReason(BigDecimal.ZERO, "MASTER", new BigDecimal("2")))
                .contains("标价为 0");
        assertThat(SalesQuoteFinanceService.blockingReason(BigDecimal.ZERO, "FINANCE", new BigDecimal("2")))
                .as("财务勾选赠品/0价").isNull();
        assertThat(SalesQuoteFinanceService.blockingReason(BigDecimal.ZERO, "MASTER", null))
                .as("文件里本来就没有单价的 0 价行不阻断").isNull();
        assertThat(SalesQuoteFinanceService.blockingReason(BigDecimal.TEN, "MASTER", new BigDecimal("9"))).isNull();
    }

    @Test
    void everyReviewActionMustNameTheRevisionItSaw() {
        SalesQuote q = quote(2, null);
        q.setReviewRevision(3);
        assertThatCode(() -> SalesQuoteService.requireRevision(q, 3)).doesNotThrowAnyException();
        assertThatThrownBy(() -> SalesQuoteService.requireRevision(q, 2))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThatThrownBy(() -> SalesQuoteService.requireRevision(q, null)).isInstanceOf(ApiException.class);
    }

    private static SalesQuote quote(int status, String returnReason) {
        SalesQuote q = new SalesQuote();
        q.setStatus((short) status);
        q.setFinanceReturnReason(returnReason);
        return q;
    }
}
