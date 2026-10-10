-- فحص حالة القاعدة: قراءة بس، ما يغيّر أي حاجة.
-- انسخه كامل وشغّله مرة وحدة في Supabase SQL Editor.
select item as "البند",
       case when ok then 'تمام' else 'ناقص' end as "النتيجة"
from (values
  (1, 'دالة فحص الأسعار موجودة',
      exists (select 1 from pg_proc where proname = '_validated_order_items')),
  (2, 'دوال الطلب تاخذ السعر من جدول المنتجات',
      coalesce((select bool_and(pg_get_functiondef(oid) like '%_validated_order_items%')
                  from pg_proc where proname in ('create_guest_order', 'create_customer_order')), false)),
  (3, 'النسخ القديمة من دوال الطلب انمسحت',
      (select count(*) from pg_proc where proname in ('create_guest_order', 'create_customer_order')) = 2),
  (4, 'الإدخال المباشر على الطلبات مسكّر',
      not exists (select 1 from pg_policies where policyname in ('orders_insert_any', 'order_items_insert_any'))),
  (5, 'إدخال الزبائن مقصور على صاحب الحساب',
      exists (select 1 from pg_policies where policyname = 'customers_insert_own')
      and not exists (select 1 from pg_policies where policyname = 'customers_insert_any')),
  (6, 'دالة is_admin تقرا من admin_users',
      coalesce((select bool_and(pg_get_functiondef(oid) like '%admin_users%')
                  from pg_proc where proname = 'is_admin'), false)),
  (7, 'فيه حساب أدمن واحد على الأقل',
      exists (select 1 from admin_users)),
  (8, 'ما فيش جدول admins زايد',
      to_regclass('public.admins') is null)
) as t(n, item, ok)
order by n;
