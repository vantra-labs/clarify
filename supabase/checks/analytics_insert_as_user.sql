-- Проверка без следов: может ли обычный вошедший пользователь (роль
-- authenticated) записать событие аналитики так, как это делает приложение.
-- Вставка внутри транзакции и откат — в базе ничего не остаётся.
begin;
do $$
declare
  someone uuid;
begin
  select user_id into someone from public.analytics_admins limit 1;
  perform set_config('request.jwt.claim.sub', someone::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', someone::text, 'role', 'authenticated')::text, true);
end $$;
set local role authenticated;
insert into public.analytics_events (event, props, platform, app_version)
values ('app_open', '{}'::jsonb, 'ci-check', 'ci');
rollback;
