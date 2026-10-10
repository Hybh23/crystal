-- =====================================================================
-- كرستال: تقوية دوال الطلبات وقواعد RLS
-- يتشغّل من Supabase Dashboard ← SQL Editor
--
-- قبل التشغيل: نزّل نسخة احتياطية من admin-backup.html
-- انسخ الملف كامل وشغّله مرة وحدة. لو صار أي خطأ ما يتغيرش شي.
-- =====================================================================


begin;

-- ---------------------------------------------------------------------
-- 0) فحص أمان تلقائي: لو الدوال ما تقدرش تتجاوز RLS، يوقف كل شي
--    وما يتغيّرش ولا حاجة.
-- ---------------------------------------------------------------------
do $$
declare
  v_func_owner  text := (select pg_get_userbyid(proowner) from pg_proc where proname = 'create_guest_order' limit 1);
  v_table_owner text := (select pg_get_userbyid(relowner) from pg_class where oid = 'public.orders'::regclass);
  v_forced      bool := (select relforcerowsecurity from pg_class where oid = 'public.orders'::regclass);
begin
  if v_func_owner is distinct from v_table_owner or v_forced then
    raise exception 'وقف: مالك الدوال (%) غير مالك الجداول (%) أو FORCE RLS مفعّل. ما تغيّر شي.', v_func_owner, v_table_owner;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1) دالة داخلية: تتحقق من عناصر السلة وتجيب السعر والاسم والوحدة من
--    جدول products. الأسعار اللي يبعتها المتصفح تتجاهل تمامًا.
-- ---------------------------------------------------------------------
create or replace function public._validated_order_items(p_items jsonb)
returns table (
  o_product_id   uuid,
  o_product_name text,
  o_color_name   text,
  o_sale_unit    text,
  o_quantity     int,
  o_unit_price   numeric,
  o_line_total   numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_item  jsonb;
  v_qty   int;
  v_color text;
  v_prod  record;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'السلة فارغة';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::int;
    if v_qty is null or v_qty < 1 or v_qty > 10000 then
      raise exception 'كمية غير صحيحة';
    end if;

    select pr.id, pr.name, pr.price, pr.sale_unit::text as sale_unit
      into v_prod
      from products pr
     where pr.id = (v_item->>'product_id')::uuid
       and pr.active = true;

    if not found then
      raise exception 'المنتج "%" لم يعد متوفرًا، احذفه من السلة', coalesce(v_item->>'product_name', '');
    end if;

    v_color := nullif(trim(v_item->>'color_name'), '');
    if v_color is not null then
      if not exists (select 1 from product_colors pc
                      where pc.product_id = v_prod.id and pc.color_name = v_color and pc.active) then
        raise exception 'اللون "%" غير متوفر للمنتج "%"', v_color, v_prod.name;
      end if;
    elsif exists (select 1 from product_colors pc where pc.product_id = v_prod.id and pc.active) then
      raise exception 'لازم يتحدد لون للمنتج "%"', v_prod.name;
    end if;

    o_product_id   := v_prod.id;
    o_product_name := v_prod.name;
    o_color_name   := v_color;
    o_sale_unit    := v_prod.sale_unit;
    o_quantity     := v_qty;
    o_unit_price   := v_prod.price;
    o_line_total   := v_qty * v_prod.price;
    return next;
  end loop;
end;
$$;

-- داخلية بس: ما تنناداش من المتصفح
revoke all on function public._validated_order_items(jsonb) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2) طلب ضيف (النسخة اللي يستعملها checkout.html: 11 مدخل)
-- ---------------------------------------------------------------------
create or replace function public.create_guest_order(
  p_customer_name text, p_customer_phone text, p_customer_second_phone text, p_shop_name text,
  p_city_id uuid, p_area text, p_address_details text, p_notes text, p_payment_method text,
  p_items jsonb, p_push_subscription_id text default null
)
returns table (result_order_number text, result_grand_total numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id    uuid;
  v_shipping       numeric;
  v_subtotal       numeric;
  v_order_id       uuid;
  v_order_number   text;
  v_status         order_status;
  v_payment_status payment_status;
  v_phone          text := regexp_replace(coalesce(p_customer_phone, ''), '[\s-]', '', 'g');
  v_phone2         text := nullif(regexp_replace(coalesce(p_customer_second_phone, ''), '[\s-]', '', 'g'), '');
begin
  if coalesce(trim(p_customer_name), '') = '' then
    raise exception 'الاسم مطلوب';
  end if;
  if v_phone !~ '^(\+218|00218|0)9[1-4][0-9]{7}$' then
    raise exception 'رقم الهاتف غير صحيح';
  end if;
  if v_phone2 is not null and v_phone2 !~ '^(\+218|00218|0)9[1-4][0-9]{7}$' then
    raise exception 'رقم الهاتف الثاني غير صحيح';
  end if;
  if coalesce(trim(p_area), '') = '' then
    raise exception 'المنطقة مطلوبة';
  end if;
  if p_payment_method not in ('cod', 'bank_transfer') then
    raise exception 'طريقة دفع غير صحيحة';
  end if;

  select shipping_price into v_shipping from cities where id = p_city_id and active = true;
  if v_shipping is null then
    raise exception 'المدينة غير صالحة';
  end if;

  select coalesce(sum(o_line_total), 0) into v_subtotal from _validated_order_items(p_items);
  if v_subtotal < 300 then
    raise exception 'قيمة الطلب أقل من الحد الأدنى (300 د.ل)';
  end if;

  insert into customers (name, phone, second_phone, shop_name, city_id, area, address_details)
  values (trim(p_customer_name), v_phone, v_phone2, p_shop_name, p_city_id, p_area, p_address_details)
  returning id into v_customer_id;

  if p_payment_method = 'bank_transfer' then
    v_status := 'pending_verification';
    v_payment_status := 'pending_verification';
  else
    v_status := 'new';
    v_payment_status := 'pending';
  end if;

  insert into orders (customer_id, status, payment_method, payment_status, city_id,
                      products_subtotal, shipping_fee, grand_total, notes, customer_push_id)
  values (v_customer_id, v_status, p_payment_method::payment_method, v_payment_status, p_city_id,
          v_subtotal, v_shipping, v_subtotal + v_shipping, p_notes, p_push_subscription_id)
  returning id, order_number into v_order_id, v_order_number;

  insert into order_items (order_id, product_id, product_name_snapshot, color_name_snapshot,
                           sale_unit_snapshot, quantity, unit_price, line_total)
  select v_order_id, o_product_id, o_product_name, o_color_name,
         o_sale_unit::sale_unit, o_quantity, o_unit_price, o_line_total
    from _validated_order_items(p_items);

  insert into order_status_history (order_id, from_status, to_status, note)
  values (v_order_id, null, v_status, 'تم إنشاء الطلب');

  return query select v_order_number, (v_subtotal + v_shipping);
end;
$$;


-- ---------------------------------------------------------------------
-- 3) طلب زبون مسجّل (النسخة اللي يستعملها checkout.html: 7 مدخلات)
-- ---------------------------------------------------------------------
create or replace function public.create_customer_order(
  p_city_id uuid, p_area text, p_address_details text, p_notes text, p_payment_method text,
  p_items jsonb, p_push_subscription_id text default null
)
returns table (result_order_number text, result_grand_total numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id    uuid;
  v_shipping       numeric;
  v_subtotal       numeric;
  v_order_id       uuid;
  v_order_number   text;
  v_status         order_status;
  v_payment_status payment_status;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولًا';
  end if;

  select id into v_customer_id from customers where auth_user_id = auth.uid() limit 1;
  if v_customer_id is null then
    raise exception 'تعذر العثور على بيانات الحساب';
  end if;

  if coalesce(trim(p_area), '') = '' then
    raise exception 'المنطقة مطلوبة';
  end if;
  if p_payment_method not in ('cod', 'bank_transfer') then
    raise exception 'طريقة دفع غير صحيحة';
  end if;

  select shipping_price into v_shipping from cities where id = p_city_id and active = true;
  if v_shipping is null then
    raise exception 'المدينة غير صالحة';
  end if;

  select coalesce(sum(o_line_total), 0) into v_subtotal from _validated_order_items(p_items);
  if v_subtotal < 300 then
    raise exception 'قيمة الطلب أقل من الحد الأدنى (300 د.ل)';
  end if;

  update customers
     set city_id = p_city_id, area = p_area,
         address_details = coalesce(p_address_details, address_details), updated_at = now()
   where id = v_customer_id;

  if p_payment_method = 'bank_transfer' then
    v_status := 'pending_verification';
    v_payment_status := 'pending_verification';
  else
    v_status := 'new';
    v_payment_status := 'pending';
  end if;

  insert into orders (customer_id, status, payment_method, payment_status, city_id,
                      products_subtotal, shipping_fee, grand_total, notes, customer_push_id)
  values (v_customer_id, v_status, p_payment_method::payment_method, v_payment_status, p_city_id,
          v_subtotal, v_shipping, v_subtotal + v_shipping, p_notes, p_push_subscription_id)
  returning id, order_number into v_order_id, v_order_number;

  insert into order_items (order_id, product_id, product_name_snapshot, color_name_snapshot,
                           sale_unit_snapshot, quantity, unit_price, line_total)
  select v_order_id, o_product_id, o_product_name, o_color_name,
         o_sale_unit::sale_unit, o_quantity, o_unit_price, o_line_total
    from _validated_order_items(p_items);

  insert into order_status_history (order_id, from_status, to_status, note)
  values (v_order_id, null, v_status, 'تم إنشاء الطلب عبر حساب مسجل');

  return query select v_order_number, (v_subtotal + v_shipping);
end;
$$;


-- ---------------------------------------------------------------------
-- 4) مسح النسخ القديمة (من غير p_push_subscription_id).
--    الموقع ما يستعملهاش، وتقعد باب خلفي لو ما تمسحتش.
-- ---------------------------------------------------------------------
drop function if exists public.create_guest_order(text, text, text, text, uuid, text, text, text, text, jsonb);
drop function if exists public.create_customer_order(uuid, text, text, text, text, jsonb);


-- ---------------------------------------------------------------------
-- 5) تثبيت search_path للدوال الباقية (تحذير Supabase Security Advisor)
-- ---------------------------------------------------------------------
alter function public.admin_update_order_status(uuid, order_status, payment_status, text) set search_path = public, extensions;
alter function public.get_order_status_public(text) set search_path = public;


-- ---------------------------------------------------------------------
-- 6) سكّر الإدخال المباشر. الطلبات تتعمل عن طريق الدوال فوق بس.
-- ---------------------------------------------------------------------
drop policy if exists orders_insert_any      on public.orders;
drop policy if exists order_items_insert_any on public.order_items;

-- الزبون يقدر يعمل صف لنفسه بس (customer-login.html عند التسجيل)
drop policy if exists customers_insert_any on public.customers;
create policy customers_insert_own on public.customers
  for insert to authenticated
  with check (auth_user_id = auth.uid());

commit;


-- =====================================================================
-- التراجع (لو صار أي مشكل في الطلبات بعد التشغيل)
-- =====================================================================
-- create policy orders_insert_any      on public.orders      for insert with check (true);
-- create policy order_items_insert_any on public.order_items for insert with check (true);
-- drop policy if exists customers_insert_own on public.customers;
-- create policy customers_insert_any   on public.customers   for insert with check (true);
