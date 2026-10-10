-- فحص إشعار الطلب الجديد للأدمن: قراءة بس، ما يغيّر أي حاجة.
-- انسخه كامل وشغّله مرة وحدة، وابعت الجدول اللي يطلع.
select * from (
  select 1 as n, 'تريقر على orders' as "البند",
         t.tgname || ' -> ' || p.oid::regprocedure::text as "التفاصيل"
    from pg_trigger t join pg_proc p on p.oid = t.tgfoid
   where t.tgrelid = 'public.orders'::regclass and not t.tgisinternal
  union all
  select 2, 'دالة تقرا admin_push_subscriptions', p.oid::regprocedure::text
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prosrc ilike '%admin_push_subscriptions%'
  union all
  select 3, 'أجهزة الأدمن المحفوظة', count(*)::text from public.admin_push_subscriptions
  union all
  select 4, 'آخر ردود OneSignal',
         coalesce(r.status_code::text, 'بلا رد') || ' | ' || left(coalesce(r.error_msg, r.content::text, ''), 200)
    from (select * from net._http_response order by created desc limit 5) r
) x
order by n;
