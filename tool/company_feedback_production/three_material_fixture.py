from pathlib import Path

def write_three_material_fixture(root: Path, out: Path) -> Path:
    # The three-material variant retains public business commands from the owning
    # fixture; it changes only synthetic BOM cardinality and receipt quantities.
    code=(root/'server/src/test/java/com/uten/imp/businesschain/WorkshopPublicSurplusEndToEndTest.java').read_text(encoding='utf8').replace('WorkshopPublicSurplusEndToEndTest','FeedbackThreeMaterialFixture')
    replacements=[('UUID extraMaterial=secondMaterial?UUID.randomUUID():null;','UUID thirdMaterial=UUID.randomUUID(); fixture.insertGoods(thirdMaterial,"QA3-"+thirdMaterial,"第三原料","采购",world.unitId(),world.unitLegacy());fixture.insertBom(product,thirdMaterial,"1");\n        UUID extraMaterial=secondMaterial?UUID.randomUUID():null;'),('fixture.insertBom(product,extraMaterial,"2")','fixture.insertBom(product,extraMaterial,"1")'),('if(secondMaterial)receiveMaterial(c,extraMaterial);','if(secondMaterial)receiveMaterial(c,extraMaterial); receiveMaterial(c,thirdMaterial);'),('line.setQty(new BigDecimal("2000")); line.setPrice','line.setQty(new BigDecimal("10000")); line.setPrice'),('line.setAmountOriginal(new BigDecimal("20000")); line.setAmountLocal(new BigDecimal("20000"));','line.setAmountOriginal(new BigDecimal("100000")); line.setAmountLocal(new BigDecimal("100000"));')]
    for before,after in replacements:
     if before not in code:raise SystemExit('Owning fixture changed: '+before)
     code=code.replace(before,after)
    fixture=out/'FeedbackThreeMaterialFixture.java';fixture.write_text(code,encoding='utf8')
    return fixture
