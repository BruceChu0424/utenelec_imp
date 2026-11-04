package com.uten.imp.features.finance.asset.api;

import jakarta.validation.constraints.*;
import java.time.LocalDate;
import java.util.UUID;

public final class AssetTemplateContracts {
    private AssetTemplateContracts() { }
    public record Save(@NotNull UUID requestId,@NotBlank @Pattern(regexp="FIXED_ASSET|DEFERRED_EXPENSE") String objectType,
            @NotNull UUID objectId,@NotNull LocalDate validFrom,@Min(-1) long expectedVersion,
            @NotNull @Size(max=240) String partyName,@NotNull @Size(max=100) String unitSpecification,
            @NotNull @Size(max=200) String categoryCaption,@NotNull @Size(max=200) String usageCaption,
            @NotNull @Size(max=80) String sourceMonth,LocalDate documentDate,
            @NotNull @Size(max=240) String firstLevelCaption,@NotNull @Size(max=240) String secondLevelCaption,
            @NotNull @Size(max=100) String acceptanceCaption,boolean confirmed,@NotBlank @Size(max=1000) String sourceReference,
            @Size(max=300)String locationCaption) {
        public Save(UUID requestId,String objectType,UUID objectId,LocalDate validFrom,long expectedVersion,String partyName,String unitSpecification,
                String categoryCaption,String usageCaption,String sourceMonth,LocalDate documentDate,String firstLevelCaption,String secondLevelCaption,
                String acceptanceCaption,boolean confirmed,String sourceReference){this(requestId,objectType,objectId,validFrom,expectedVersion,partyName,unitSpecification,
                    categoryCaption,usageCaption,sourceMonth,documentDate,firstLevelCaption,secondLevelCaption,acceptanceCaption,confirmed,sourceReference,null);}
    }
    public record Saved(UUID requestId,UUID metadataId,long version) { }
}
