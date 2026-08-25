package com.uten.imp.common.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class StandardDocumentLifecycleCapabilitiesTest {

    @Test
    void standardStatusesSerializeExplicitFailClosedCapabilities() {
        ObjectMapper mapper = new ObjectMapper();

        var draft = mapper.valueToTree(new Stub((short) 0));
        assertThat(draft.get("canEdit").asBoolean()).isTrue();
        assertThat(draft.get("canDelete").asBoolean()).isTrue();
        assertThat(draft.get("canReverse").asBoolean()).isFalse();

        var approved = mapper.valueToTree(new Stub((short) 1));
        assertThat(approved.get("canEdit").asBoolean()).isFalse();
        assertThat(approved.get("canDelete").asBoolean()).isFalse();
        assertThat(approved.get("canReverse").asBoolean()).isTrue();

        var unknown = mapper.valueToTree(new Stub(null));
        assertThat(unknown.get("canEdit").asBoolean()).isFalse();
        assertThat(unknown.get("canDelete").asBoolean()).isFalse();
        assertThat(unknown.get("canReverse").asBoolean()).isFalse();
    }

    @Test
    void deleteRequiresDraftAndPreservesApprovedReversedAndUnknownHistory() {
        assertThatCode(() ->
                StandardDocumentLifecycleCapabilities.requireDraftForDelete((short) 0))
                .doesNotThrowAnyException();

        for (Short status : new Short[]{null, (short) 1, (short) -1}) {
            assertThatThrownBy(() ->
                    StandardDocumentLifecycleCapabilities.requireDraftForDelete(status))
                    .isInstanceOfSatisfying(ApiException.class, error -> {
                        assertThat(error.getCode()).isEqualTo(ErrorCode.BUSINESS);
                        assertThat(error.getMessage()).contains("仅草稿", "红冲历史必须保留");
                    });
        }
    }

    @Test
    void everySupportedNonOrderDetailUsesTheSharedCapabilityContract() {
        for (Class<?> detail : List.of(
                com.uten.imp.features.purchase.receipt.dto.ReceiptDetail.class,
                com.uten.imp.features.purchase.ret.dto.ReturnDetail.class,
                com.uten.imp.features.subcontract.inquiry.dto.InquiryDetail.class,
                com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail.class,
                com.uten.imp.features.subcontract.material_return.dto.MaterialReturnDetail.class,
                com.uten.imp.features.subcontract.receipt.dto.ReceiptDetail.class,
                com.uten.imp.features.subcontract.ret.dto.ReturnDetail.class,
                com.uten.imp.features.subcontract.waste.dto.WasteDetail.class)) {
            assertThat(StandardDocumentLifecycleCapabilities.class)
                    .as(detail.getName())
                    .isAssignableFrom(detail);
        }
    }

    private record Stub(Short status)
            implements StandardDocumentLifecycleCapabilities {
        @Override
        public Short getStatus() {
            return status;
        }
    }
}
