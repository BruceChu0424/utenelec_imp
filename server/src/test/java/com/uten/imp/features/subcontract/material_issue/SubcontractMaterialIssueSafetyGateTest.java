package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * V221 放开了原"无台账即 409"门禁，改为：发料审核必须冻结 BOM + 建供应商处子件台账，
 * 且每条明细必须挂委外订货明细（order_item_id）以便回厂按 BOM 守恒消费。
 *
 * <p>本测试钉住新的 fail-closed 不变量：缺 order_item_id 的发料明细在动库存前被拒。
 * 完整守恒（回厂按 BOM 消费 + supplier_ending≥0）由 Testcontainers 守恒测试覆盖。
 */
class SubcontractMaterialIssueSafetyGateTest {

    @Test
    void approvalRequiresOrderItemLinkageBeforePostingInventory() {
        SubcontractMaterialIssueRepository issueRepo =
                mock(SubcontractMaterialIssueRepository.class);
        SubcontractMaterialIssueItemRepository itemRepo =
                mock(SubcontractMaterialIssueItemRepository.class);
        StockService stockService = mock(StockService.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        EntityManager em = mock(EntityManager.class);
        SubcontractMaterialIssueService service =
                new SubcontractMaterialIssueService(
                        issueRepo,
                        itemRepo,
                        stockService,
                        tx,
                        em,
                        mock(SecurityContextCurrentUser.class),
                        mock(EmployeeNameResolver.class),
                        mock(DocNumberService.class),
                        mock(com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy.class));

        UUID id = UUID.randomUUID();
        SubcontractMaterialIssue document = new SubcontractMaterialIssue();
        document.setId(id);
        document.setStatus((short) 0);
        document.setWarehouseId(UUID.randomUUID());
        when(em.find(SubcontractMaterialIssue.class, id, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(document);

        SubcontractMaterialIssueItem item = new SubcontractMaterialIssueItem();
        item.setIssueId(id);
        item.setQty(new BigDecimal("10"));
        item.setGoodsId(UUID.randomUUID());
        // orderItemId intentionally left null → must be rejected before inventory is touched.
        when(itemRepo.findByIssueIdOrderByLineNoAsc(id)).thenReturn(List.of(item));

        ApiException error = assertThrows(ApiException.class, () -> service.approve(id));

        assertEquals(ErrorCode.BUSINESS, error.getCode());
        assertTrue(error.getMessage().contains("委外订货明细"));
        verifyNoInteractions(stockService);
    }
}
