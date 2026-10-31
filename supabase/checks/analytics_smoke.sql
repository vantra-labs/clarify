-- Проверка без изменений в базе: считается ли сводка аналитики от имени
-- админа. Падение = ошибка в analytics_summary(). Запуск — workflow
-- «Применить SQL к базе» с этим файлом. Всё в транзакции, ничего не пишет.
do $$
declare
  admin uuid;
  r jsonb;
begin
  select user_id into admin from public.analytics_admins limit 1;
  if admin is null then
    raise exception 'нет ни одного админа аналитики';
  end if;
  perform set_config('request.jwt.claim.sub', admin::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', admin::text, 'role', 'authenticated')::text, true);
  r := public.analytics_summary(30);
  if r ? 'users_total' is not true then
    raise exception 'сводка без users_total: %', r;
  end if;
end $$;
