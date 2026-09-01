package com.uten.imp.features.subcontract.inquiry;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryDetail;
import com.uten.imp.features.subcontract.inquiry.dto.InquiryItemDto;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SubcontractInquiryPriceVisibilityTest {

    @Mock private SubcontractInquiryRepository inquiryRepository;
    @Mock private SubcontractInquiryItemRepository itemRepository;
    @Mock private TxSessionVars tx;
    @Mock private DocNumberService numbers;
    @Mock private EntityManager entityManager;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private EmployeeNameResolver names;
    @Mock private SubcontractDocumentAccessPolicy access;
    @Mock private CommercialPriceVisibility commercialVisibility;
    @InjectMocks private SubcontractInquiryService service;

    @Test
    void missingInquiryPricePermissionMasksHeaderAndLinesServerSide() {
        when(commercialVisibility.canViewSubcontractInquiry()).thenReturn(false);
        SubcontractInquiry inquiry = new SubcontractInquiry();
        inquiry.setMakerId(UUID.randomUUID());
        inquiry.setCurrencyId(UUID.randomUUID());
        inquiry.setExchangeRate(new BigDecimal("7.2"));
        inquiry.setTotalOriginal(new BigDecimal("20"));
        inquiry.setTotalLocal(new BigDecimal("144"));

        SubcontractInquiryItem item = new SubcontractInquiryItem();
        item.setQty(new BigDecimal("2"));
        item.setPrice(new BigDecimal("10"));
        item.setAmountOriginal(new BigDecimal("20"));
        item.setAmountLocal(new BigDecimal("144"));
        InquiryItemDto dto = ReflectionTestUtils.invokeMethod(
                service, "toItemDto", item);
        InquiryDetail detail = ReflectionTestUtils.invokeMethod(
                service, "toDetail", inquiry, List.of(dto));

        assertTrue(detail.isPriceMasked());
        assertNull(detail.getCurrencyId());
        assertNull(detail.getExchangeRate());
        assertNull(detail.getTotalOriginal());
        assertNull(detail.getTotalLocal());
        assertNull(detail.getItems().getFirst().getPrice());
        assertEquals(new BigDecimal("2"), detail.getItems().getFirst().getQty());
    }
}
