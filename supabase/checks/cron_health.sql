-- Проверка без изменений: служебные маршруты, которые дёргает pg_cron, за
-- последние 20 минут отвечали 200. Падение = после выкладки что-то сломалось.
do $$
declare
  bad int;
  total int;
begin
  select count(*), count(*) filter (where status_code is distinct from 200)
    into total, bad
  from net._http_response
  where created > now() - interval '20 minutes';
  if total = 0 then
    raise exception 'за 20 минут ни одного ответа — pg_cron не работает?';
  end if;
  if bad > 0 then
    raise exception 'неуспешных ответов: % из %: %', bad, total, (
      select string_agg(coalesce(status_code::text,'null') || ' ' || left(coalesce(content, error_msg, ''), 60), ' | ')
      from (select * from net._http_response where created > now() - interval '20 minutes'
            and status_code is distinct from 200 order by created desc limit 3) x);
  end if;
end $$;
