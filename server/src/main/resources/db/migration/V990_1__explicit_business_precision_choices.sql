-- No hidden decimal projection. Java and SQL accept the same per-request user choices.
CREATE FUNCTION fn_business_decimal_from_integer(p_integer numeric,p_scale integer) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE digits text;length integer;
BEGIN
 IF p_scale<0 OR p_scale>1000 OR p_integer<>trunc(p_integer) THEN RAISE EXCEPTION 'Invalid exact decimal representation' USING ERRCODE='22023';END IF;
 IF p_scale=0 THEN RETURN p_integer;END IF;
 digits:=abs(p_integer)::text;digits:=split_part(digits,'.',1);
 digits:=lpad(digits,greatest(length(digits),p_scale+1),'0');length:=length(digits);
 RETURN ((CASE WHEN p_integer<0 THEN '-' ELSE '' END)||left(digits,length-p_scale)||'.'||right(digits,p_scale))::numeric;
END $$;

CREATE FUNCTION fn_business_exact_divide_with_policy(p_numerator numeric,p_denominator numeric,p_key text,p_label text,p_max_scale integer,p_policy jsonb,p_record_used boolean)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
DECLARE n numeric;d numeric;first numeric;second numeric;remainder numeric;common numeric;factor numeric;
        twos integer:=0;fives integer:=0;places integer;adjusted numeric;choice jsonb;settings jsonb;
        selected integer;mode text;quotient numeric;reason text:='NON_TERMINATING';details jsonb;result numeric;
BEGIN
 IF p_numerator::text IN('NaN','Infinity','-Infinity') OR p_denominator::text IN('NaN','Infinity','-Infinity') THEN
  RAISE EXCEPTION 'Business decimal input must be finite' USING ERRCODE='22003';END IF;
 IF p_numerator IS NULL OR p_denominator IS NULL OR p_denominator=0 THEN RETURN NULL;END IF;
 IF p_numerator=0 THEN RETURN 0;END IF;
 IF p_max_scale<0 OR p_max_scale>30 OR p_key IS NULL OR length(p_key)>200 OR length(trim(p_key))=0 THEN
  RAISE EXCEPTION 'Invalid business precision purpose' USING ERRCODE='22023';END IF;
 IF greatest(scale(p_numerator),scale(p_denominator))>1000 THEN
  RAISE EXCEPTION 'Business decimal input exceeds the supported exact range' USING ERRCODE='22003';END IF;
 -- Work with integers. PostgreSQL numeric division itself may project a
 -- repeating or very long finite quotient; it is never used as an oracle.
 n:=p_numerator*('1'||repeat('0',greatest(scale(p_numerator),0)))::numeric;
 d:=p_denominator*('1'||repeat('0',greatest(scale(p_denominator),0)))::numeric;
 n:=n*('1'||repeat('0',greatest(scale(p_denominator),0)))::numeric;
 d:=d*('1'||repeat('0',greatest(scale(p_numerator),0)))::numeric;
 IF d<0 THEN n:=-n;d:=-d;END IF;
 first:=abs(n);second:=d;
 WHILE second<>0 LOOP remainder:=mod(first,second);first:=second;second:=remainder;END LOOP;
 common:=first;n:=div(n,common);d:=div(d,common);factor:=d;
 WHILE mod(factor,2)=0 LOOP factor:=div(factor,2);twos:=twos+1;END LOOP;
 WHILE mod(factor,5)=0 LOOP factor:=div(factor,5);fives:=fives+1;END LOOP;
 IF factor=1 THEN
  places:=greatest(twos,fives);
  IF places<=p_max_scale THEN
   adjusted:=n;
   FOR i IN 1..places-twos LOOP adjusted:=adjusted*2;END LOOP;
   FOR i IN 1..places-fives LOOP adjusted:=adjusted*5;END LOOP;
   RETURN fn_business_decimal_from_integer(adjusted,places);
  END IF;
  reason:='PRECISION_LIMIT';
 END IF;
 settings:=COALESCE(p_policy,'{}'::jsonb);
 choice:=settings->'choices'->p_key;
 IF choice IS NULL OR choice='null'::jsonb THEN
  details:=jsonb_build_object('calculationKey',p_key,'groupKey',p_key,'label',p_label,'maxScale',p_max_scale,'reason',reason,'notWritten',true);
  RAISE EXCEPTION 'UTEN_PRECISION_REQUIRED:%',details::text USING ERRCODE='22023';
 END IF;
 IF jsonb_typeof(choice->'scale') IS DISTINCT FROM 'number' OR ((choice->>'scale')~'^[0-9]+$') IS NOT TRUE THEN RAISE EXCEPTION '数值保留位数无效，请重新选择' USING ERRCODE='22023';END IF;
 selected:=(choice->>'scale')::integer;mode:=choice->>'rounding';
 IF selected<0 OR selected>p_max_scale OR mode IS NULL OR mode NOT IN('HALF_UP','DOWN') THEN RAISE EXCEPTION '数值处理方式超出本字段范围，请重新选择' USING ERRCODE='22023';END IF;
 adjusted:=abs(n)*('1'||repeat('0',selected))::numeric;
 quotient:=div(adjusted,d);remainder:=mod(adjusted,d);
 IF mode='HALF_UP' AND remainder*2>=d THEN quotient:=quotient+1;END IF;
 IF n<0 THEN quotient:=-quotient;END IF;
 result:=fn_business_decimal_from_integer(quotient,selected);
 -- Only the explicitly used policy is retained here, not a second business ledger.
 IF p_record_used THEN
  PERFORM set_config('app.business_precision_used',(COALESCE(NULLIF(current_setting('app.business_precision_used',true),''),'{}')::jsonb||jsonb_build_object(p_key,choice))::text,true);
 END IF;
 RETURN result;
END $$;

CREATE FUNCTION fn_business_exact_divide(p_numerator numeric,p_denominator numeric,p_key text,p_label text,p_max_scale integer DEFAULT 30)
RETURNS numeric LANGUAGE sql VOLATILE AS $$
 SELECT fn_business_exact_divide_with_policy(p_numerator,p_denominator,p_key,p_label,p_max_scale,
   COALESCE(NULLIF(current_setting('app.business_precision_choices',true),'')::jsonb,'{}'::jsonb),true)
$$;

CREATE FUNCTION fn_business_precision_snapshot() RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT jsonb_build_object('version',1,'choices',COALESCE(NULLIF(current_setting('app.business_precision_choices',true),'')::jsonb->'choices','{}'::jsonb))
$$;

CREATE FUNCTION fn_business_precision_limit(p_value numeric,p_key text,p_label text,p_max_scale integer)
RETURNS numeric LANGUAGE sql VOLATILE AS $$SELECT fn_business_exact_divide(p_value,1,p_key,p_label,p_max_scale)$$;

-- The same original/local book split as Java FinancialBookAllocation. A source
-- remainder is retained, while non-final division requires a user policy.
CREATE OR REPLACE FUNCTION fn_financial_book_part(p_amount numeric,p_before_original numeric,p_before_local numeric)
RETURNS numeric LANGUAGE plpgsql VOLATILE STRICT AS $$
BEGIN
 IF p_amount<0 OR p_before_original<=0 OR p_amount>p_before_original OR p_before_local<0 THEN
  RAISE EXCEPTION 'invalid finite book allocation basis' USING ERRCODE='23514';END IF;
 IF p_amount=p_before_original THEN RETURN p_before_local;END IF;
 RETURN fn_business_exact_divide(p_before_local*p_amount,p_before_original,'money.book-share','本次账面金额分摊',30);
END $$;

-- Historical facts retain their original v1 source allocation. This function
-- is only for verifying an already frozen proof, never for creating new value.
CREATE FUNCTION fn_financial_book_part_legacy_proof_v1(p_amount numeric,p_before_original numeric,p_before_local numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE STRICT AS $$
BEGIN
 IF p_amount<0 OR p_before_original<=0 OR p_amount>p_before_original OR p_before_local<0 THEN
  RAISE EXCEPTION 'invalid historical book allocation basis' USING ERRCODE='23514';END IF;
 IF p_amount=p_before_original THEN RETURN p_before_local;END IF;
 RETURN div(p_before_local*p_amount*1e30::numeric,p_before_original)*1e-30::numeric;
END $$;

-- A new proof includes a non-null policy, even if no lossy calculation was
-- needed. Later confirmation/reversal verifies that frozen decision rather
-- than asking a different user or borrowing a new request's choices.
CREATE FUNCTION fn_financial_book_part_proof(p_amount numeric,p_before_original numeric,p_before_local numeric,p_policy jsonb)
RETURNS numeric LANGUAGE plpgsql VOLATILE AS $$
BEGIN
 IF p_amount IS NULL OR p_before_original IS NULL OR p_before_local IS NULL THEN RETURN NULL;END IF;
 IF p_policy IS NULL THEN RETURN fn_financial_book_part_legacy_proof_v1(p_amount,p_before_original,p_before_local);END IF;
 IF (p_policy->>'version') IS DISTINCT FROM '1' OR jsonb_typeof(p_policy->'choices') IS DISTINCT FROM 'object' THEN
  RAISE EXCEPTION 'invalid frozen business precision policy' USING ERRCODE='23514';END IF;
 IF p_amount<0 OR p_before_original<=0 OR p_amount>p_before_original OR p_before_local<0 THEN
  RAISE EXCEPTION 'invalid frozen book allocation basis' USING ERRCODE='23514';END IF;
 IF p_amount=p_before_original THEN RETURN p_before_local;END IF;
 RETURN fn_business_exact_divide_with_policy(p_before_local*p_amount,p_before_original,
    'money.book-share','已冻结账面金额分摊',30,p_policy,false);
END $$;
