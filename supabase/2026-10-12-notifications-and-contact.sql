-- =====================================================================
-- كرستال: إشعار الأدمن بالطلب الجديد، إشعارات الزبون بالعربي،
--          وأرقام تواصل لكل طلب
-- انسخ الملف كامل وشغّله مرة وحدة في Supabase SQL Editor، **قبل** دمج
-- تعديلات الموقع. لو صار أي خطأ ما يتغيرش شي.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1) أرقام التواصل الخاصة بكل طلب (الزبون المسجّل يقدر يغيّرها وقت الطلب
--    من غير ما يتغيّر رقم حسابه اللي يدخل بيه)
-- ---------------------------------------------------------------------
alter table public.orders
  add column if not exists contact_phone        text,
  add column if not exists contact_second_phone text;


-- ---------------------------------------------------------------------
-- 2) طلب زبون مسجّل: يقبل رقم تواصل ورقم ثاني
--    (النسخة القديمة تنمسح، والجديدة تشتغل حتى لو الموقع القديم ناداها
--     من غير الأرقام، لأنهم اختياريين)
-- ---------------------------------------------------------------------
drop function if exists public.create_customer_order(uuid, text, text, text, text, jsonb, text);

create or replace function public.create_customer_order(
  p_city_id uuid, p_area text, p_address_details text, p_notes text, p_payment_method text,
  p_items jsonb, p_push_subscription_id text default null,
  p_contact_phone text default null, p_contact_second_phone text default null
)
returns table (result_order_number text, result_grand_total numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id    uuid;
  v_account_phone  text;
  v_shipping       numeric;
  v_subtotal       numeric;
  v_order_id       uuid;
  v_order_number   text;
  v_status         order_status;
  v_payment_status payment_status;
  v_phone          text := nullif(regexp_replace(coalesce(p_contact_phone, ''), '[\s-]', '', 'g'), '');
  v_phone2         text := nullif(regexp_replace(coalesce(p_contact_second_phone, ''), '[\s-]', '', 'g'), '');
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولًا';
  end if;

  select id, phone into v_customer_id, v_account_phone
    from customers where auth_user_id = auth.uid() limit 1;
  if v_customer_id is null then
    raise exception 'تعذر العثور على بيانات الحساب';
  end if;

  v_phone := coalesce(v_phone, v_account_phone);
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

  -- الرقم الثاني ينحفظ في ملف الزبون عشان يتعبى تلقائيًا المرة الجاية
  update customers
     set city_id = p_city_id, area = p_area,
         address_details = coalesce(p_address_details, address_details),
         second_phone = coalesce(v_phone2, second_phone),
         updated_at = now()
   where id = v_customer_id;

  if p_payment_method = 'bank_transfer' then
    v_status := 'pending_verification';
    v_payment_status := 'pending_verification';
  else
    v_status := 'new';
    v_payment_status := 'pending';
  end if;

  insert into orders (customer_id, status, payment_method, payment_status, city_id,
                      products_subtotal, shipping_fee, grand_total, notes, customer_push_id,
                      contact_phone, contact_second_phone)
  values (v_customer_id, v_status, p_payment_method::payment_method, v_payment_status, p_city_id,
          v_subtotal, v_shipping, v_subtotal + v_shipping, p_notes, p_push_subscription_id,
          v_phone, v_phone2)
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

grant execute on function public.create_customer_order(uuid, text, text, text, text, jsonb, text, text, text)
  to anon, authenticated;


-- ---------------------------------------------------------------------
-- 3) إشعار الزبون بتغيّر حالة طلبه: بالعربي دايمًا، وفيه رقم الطلب.
--    OneSignal يختار النص حسب لغة جهاز الزبون، فحتى خانة "en" عربي.
-- ---------------------------------------------------------------------
create or replace function public.admin_update_order_status(
  p_order_id uuid, p_new_status order_status,
  p_new_payment_status payment_status default null, p_cancel_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_old_status   order_status;
  v_push_id      text;
  v_order_number text;
  v_key          text;
  v_title        text;
  v_text         text;
begin
  if not is_admin() then
    raise exception 'صلاحية غير كافية';
  end if;

  select status, customer_push_id, order_number
    into v_old_status, v_push_id, v_order_number
    from orders where id = p_order_id;

  update orders
     set status = p_new_status,
         payment_status = coalesce(p_new_payment_status, payment_status),
         cancel_reason = coalesce(p_cancel_reason, cancel_reason),
         updated_at = now()
   where id = p_order_id;

  insert into order_status_history (order_id, from_status, to_status, changed_by, note)
  values (p_order_id, v_old_status, p_new_status, auth.uid(), p_cancel_reason);

  if v_push_id is null or v_old_status is not distinct from p_new_status then
    return;
  end if;

  v_title := 'كرستال: تحديث على طلبك #' || v_order_number;
  v_text := case p_new_status
    when 'new'              then 'تم تأكيد طلبك #' || v_order_number || ' وبدينا نجهّزوا فيه 👍'
    when 'prepared'         then 'طلبك #' || v_order_number || ' تجهّز وقاعد يستنى التوصيل 📦'
    when 'out_for_delivery' then 'طلبك #' || v_order_number || ' طلع مع التوصيل وهو في الطريق ليك 🚚'
    when 'delivered'        then 'تم تسليم طلبك #' || v_order_number || '. شكرًا لتسوقك من كرستال 🤍'
    when 'cancelled'        then 'تم إلغاء طلبك #' || v_order_number
                                 || coalesce(' (' || nullif(trim(p_cancel_reason), '') || ')', '')
                                 || '. للاستفسار تواصل معانا'
    else 'فيه تغيير على طلبك #' || v_order_number || '، افحصه من هنا'
  end;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'onesignal_rest_key';

  perform net.http_post(
    url     := 'https://api.onesignal.com/notifications',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Key ' || v_key),
    body    := jsonb_build_object(
      'app_id', 'c8318950-edb6-4899-bc3b-19189079f1d0',
      'include_subscription_ids', jsonb_build_array(v_push_id),
      'headings', jsonb_build_object('ar', v_title, 'en', v_title),
      'contents', jsonb_build_object('ar', v_text,  'en', v_text),
      'url', 'https://crystalstore.ly/order-status.html?order=' || v_order_number
    )
  );
end;
$$;


-- ---------------------------------------------------------------------
-- 4) إشعار الأدمن بكل طلب جديد. يتبعت لكل الأجهزة المحفوظة في
--    admin_push_subscriptions. أي خطأ في الإرسال ما يوقفش الطلب.
-- ---------------------------------------------------------------------
create or replace function public.notify_admins_new_order()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ids      jsonb;
  v_key      text;
  v_customer text;
  v_text     text;
begin
  select jsonb_agg(distinct subscription_id) into v_ids
    from admin_push_subscriptions where subscription_id is not null;
  if v_ids is null then
    return new;
  end if;

  select name into v_customer from customers where id = new.customer_id;

  v_text := coalesce(v_customer, 'زبون') || ' | '
            || to_char(new.grand_total, 'FM999999990.00') || ' د.ل | '
            || case new.payment_method::text when 'bank_transfer' then 'تحويل مصرفي' else 'دفع عند الاستلام' end;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'onesignal_rest_key';

  perform net.http_post(
    url     := 'https://api.onesignal.com/notifications',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Key ' || v_key),
    body    := jsonb_build_object(
      'app_id', 'c8318950-edb6-4899-bc3b-19189079f1d0',
      'include_subscription_ids', v_ids,
      'headings', jsonb_build_object('ar', 'طلب جديد #' || new.order_number, 'en', 'طلب جديد #' || new.order_number),
      'contents', jsonb_build_object('ar', v_text, 'en', v_text),
      'url', 'https://crystalstore.ly/admin-orders.html'
    )
  );
  return new;
exception when others then
  -- الإشعار مش أهم من الطلب: لو فشل، الطلب يتسجل عادي
  return new;
end;
$$;

revoke all on function public.notify_admins_new_order() from public, anon, authenticated;

drop trigger if exists trg_notify_admins_new_order on public.orders;
create trigger trg_notify_admins_new_order
  after insert on public.orders
  for each row execute function public.notify_admins_new_order();

commit;


-- ---------------------------------------------------------------------
-- 5) للتأكد: كل التريقرات على جدول الطلبات، وكم جهاز أدمن محفوظ.
--    المفروض يطلع trg_notify_admins_new_order. لو طلع تريقر ثاني يبعت
--    إشعارات، ابعته عشان ما يجيكش الإشعار مرتين.
-- ---------------------------------------------------------------------
select t.tgname as "التريقر",
       p.proname as "الدالة",
       (select count(*) from public.admin_push_subscriptions) as "أجهزة الأدمن"
  from pg_trigger t join pg_proc p on p.oid = t.tgfoid
 where t.tgrelid = 'public.orders'::regclass and not t.tgisinternal;
