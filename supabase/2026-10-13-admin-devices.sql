-- =====================================================================
-- كرستال: أجهزة إشعارات الأدمن
-- 1) الجهاز يتبع آخر أدمن فعّل التنبيهات عليه (قبل كان يرفض لو الجهاز
--    مسجّل باسم أدمن ثاني، ويطلع خطأ row-level security).
-- 2) الزبون ما يقدرش يسجّل جهازه في أجهزة الأدمن (قبل كان يقدر، وتوصله
--    إشعارات الطلبات الجديدة بأسماء الزبائن ومبالغهم).
-- انسخ الملف كامل وشغّله مرة وحدة في Supabase SQL Editor.
-- =====================================================================

begin;

drop policy if exists admin_push_subs_own_insert on public.admin_push_subscriptions;
create policy admin_push_subs_admin_insert on public.admin_push_subscriptions
  for insert
  with check (auth.uid() = user_id and is_admin());

drop policy if exists admin_push_subs_own_upsert on public.admin_push_subscriptions;
create policy admin_push_subs_admin_update on public.admin_push_subscriptions
  for update
  using (is_admin())
  with check (auth.uid() = user_id and is_admin());

-- أي جهاز تسجّل قبل من حساب مش أدمن ينمسح
delete from public.admin_push_subscriptions
 where user_id not in (select user_id from public.admin_users);

commit;
