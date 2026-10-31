-- Шаг 2 проверки вебхуков: ответ на пробный запрос из шага 1.
do $$
declare
  r record;
begin
  select status_code, content into r
  from net._http_response
  where created > now() - interval '30 minutes'
    and content like '%"sent":0%'
  order by created desc
  limit 1;
  if r is null then
    raise exception 'нет успешного ответа обработчика за 30 минут: %', (
      select string_agg(coalesce(status_code::text, 'null') || ' ' || left(coalesce(content, error_msg, ''), 80), ' | ')
      from (select * from net._http_response where created > now() - interval '30 minutes' order by created desc limit 3) x
    );
  end if;
  if r.status_code <> 200 then
    raise exception 'обработчик ответил %', r.status_code;
  end if;
end $$;
