-- =====================================================================
-- كرستال: تصليح تسجيل الزبائن الجدد
-- انسخ الملف كامل وشغّله مرة وحدة في Supabase SQL Editor.
-- لو صار أي خطأ ما يتغيرش شي.
-- =====================================================================

begin;

-- 1) صف customers يتعمل تلقائيًا مع كل حساب زبون جديد (من جهة السيرفر،
--    فما يعتمدش على إن المتصفح عنده session وقت التسجيل).
create or replace function public.handle_new_customer_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.email ~* '^0[0-9]{9}@crystalstore\.ly$' then
    insert into public.customers (auth_user_id, name, phone, area)
    select new.id,
           coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)),
           split_part(new.email, '@', 1),
           ''
     where not exists (select 1 from public.customers where auth_user_id = new.id);
  end if;
  return new;
end;
$$;

revoke all on function public.handle_new_customer_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_customer on auth.users;
create trigger on_auth_user_created_customer
  after insert on auth.users
  for each row execute function public.handle_new_customer_user();


-- 2) الحسابات اللي تعملت قبل وما تعملهاش صف customers (بسبب الخطأ)
insert into public.customers (auth_user_id, name, phone, area)
select u.id,
       coalesce(nullif(trim(u.raw_user_meta_data->>'name'), ''), split_part(u.email, '@', 1)),
       split_part(u.email, '@', 1),
       ''
  from auth.users u
 where u.email ~* '^0[0-9]{9}@crystalstore\.ly$'
   and not exists (select 1 from public.customers c where c.auth_user_id = u.id);


-- 3) تفعيل حسابات الزبائن الموجودة. الإيميل وهمي وما يوصلش، فالحساب
--    ما يتفعّلش أبدًا لو ما فعّلناهوش من هنا.
update auth.users
   set email_confirmed_at = now()
 where email ~* '^0[0-9]{9}@crystalstore\.ly$'
   and email_confirmed_at is null;

commit;
