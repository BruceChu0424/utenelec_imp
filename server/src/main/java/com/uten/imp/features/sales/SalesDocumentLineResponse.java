package com.uten.imp.features.sales;

import com.uten.imp.common.columns.ExtraColumnResponse;
import lombok.Getter;
import lombok.Setter;

/** Sales-specific optional labels shared by quotation and order responses. */
@Getter
@Setter
public abstract class SalesDocumentLineResponse extends ExtraColumnResponse {
    private String goodsNameEn;
}
