package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verifyNoInteractions;

@ExtendWith(MockitoExtension.class)
class GoodsReferenceFacetNormalizationTest {
    @Mock Root<Goods> root;
    @Mock CriteriaBuilder criteria;

    @Test
    void canonicalLegacyBoundsAndOptionalFiltersKeepTheirMeaning() {
        assertThat(GoodsReferenceFacet.normalize(null)).isNull();
        assertThat(GoodsReferenceFacet.normalize(" ")).isNull();
        assertThat(GoodsReferenceFacet.normalize("0")).isEqualTo("legacy:0");
        assertThat(GoodsReferenceFacet.normalize(" 2147483647 ")).isEqualTo("legacy:2147483647");
        assertThat(GoodsReferenceFacet.normalize("legacy:2147483647")).isEqualTo("legacy:2147483647");
    }

    @Test
    void malformedOrOverflowedKeysFailBeforeBuildingAnyDatabasePredicate() {
        for (String value : List.of("2147483648", "-1", "01", "1.5", "legacy:01", "legacy:2147483648")) {
            assertThatThrownBy(() -> GoodsReferenceFacet.matches(root, criteria, "unitRef", value))
                    .isInstanceOfSatisfying(ApiException.class,
                            failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
        verifyNoInteractions(root, criteria);
    }
}
