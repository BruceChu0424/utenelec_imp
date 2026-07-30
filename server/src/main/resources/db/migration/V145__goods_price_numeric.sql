-- 货品价格从二进制浮点收敛为精确十进制。
-- API/JPA 使用 BigDecimal；NUMERIC(18,4) 与采购、销售、库存单价口径一致。
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM goods
        WHERE price IS NOT NULL
          AND price::text IN ('NaN', 'Infinity', '-Infinity')
    ) THEN
        RAISE EXCEPTION
            'goods.price contains NaN/Infinity and cannot be converted to NUMERIC(18,4)';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM goods
        WHERE price IS NOT NULL
          AND abs(round(price::numeric, 4)) >= 100000000000000::numeric
    ) THEN
        RAISE EXCEPTION
            'goods.price contains values outside NUMERIC(18,4) range';
    END IF;
END
$$;

ALTER TABLE goods
    ALTER COLUMN price TYPE NUMERIC(18,4)
    USING round(price::numeric, 4);

COMMENT ON COLUMN goods.price IS
    '货品单价；精确十进制 NUMERIC(18,4)，禁止通过 double/float 写入';
