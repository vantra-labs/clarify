-- Шаг 1 проверки вебхуков: структура + пробный запрос в обработчик.
-- Пейлоад с table = 'probe' обработчик не узнаёт и никому ничего не шлёт —
-- ответ {"ok":true,"sent":0} значит только «адрес верный, токен принят».
-- Ответ pg_net приходит после коммита, его смотрит шаг 2:
-- notify_webhooks_check.sql (запускать через минуту).
do $$
declare
  token text;
begin
  if exists (select 1 from pg_trigger where tgname in ('Messages ', 'Tasks', 'Workspace_messages')) then
    raise exception 'старые триггеры на Render ещё на месте';
  end if;
  if (select count(*) from pg_trigger where tgname like 'notify_event_%' and not tgisinternal) <> 4 then
    raise exception 'новых триггеров не 4';
  end if;
  select value into token from private.app_secrets where name = 'internal_push_token';
  perform net.http_post(
    url := 'https://laghxzqqgxhspwcbbcml.supabase.co/functions/v1/api/internal/notify-event',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Internal-Token', token, 'X-Clarify-Probe', '1'),
    body := '{"table":"probe","record":{}}'::jsonb,
    timeout_milliseconds := 15000
  );
end $$;
