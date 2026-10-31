-- Вебхуки уведомлений → Edge Function вместо мёртвого Render (31.10.2026).
--
-- Что было. Три Database Webhook-триггера ("Messages ", "Tasks",
-- "Workspace_messages") слали каждое изменение на
-- clarify-backend-g6np.onrender.com/internal/notify-event. Бэкенд переехал в
-- Edge Function 08.09.2026, а триггеры остались смотреть на Render, адреса
-- которого из России не открываются. Итог: молча не работали уведомления
-- «вам назначили задачу» и о новых сообщениях. Плюс внутренний токен лежал
-- открытым текстом прямо в определении триггера — и попадал в снимок схемы.
--
-- Что стало.
--   * Токен хранится в private.app_secrets (схема не выставлена в API, прав
--     у anon/authenticated нет). Берётся из уже работающего задания pg_cron,
--     так что руками его никуда вставлять не нужно.
--   * Одна функция-обработчик шлёт тот же формат, что Database Webhooks
--     (type/table/schema/record/old_record), на /functions/v1/api/internal/notify-event.
--   * Задачи: триггер срабатывает только на смену исполнителя (было — на
--     КАЖДОЕ обновление задачи, то есть на каждый чекбокс). При создании —
--     только если задачу сразу назначили не себе.
--
-- Идемпотентно.

create extension if not exists pg_net;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.app_secrets (
  name text primary key,
  value text not null
);
revoke all on private.app_secrets from public, anon, authenticated;

insert into private.app_secrets (name, value)
select 'internal_push_token',
       substring(command from 'X-Internal-Token'',\s*''([^'']+)''')
from cron.job
where jobname = 'clarify-check-due-tasks'
  and substring(command from 'X-Internal-Token'',\s*''([^'']+)''') is not null
on conflict (name) do nothing;

do $$
begin
  if not exists (select 1 from private.app_secrets where name = 'internal_push_token' and value <> '') then
    raise exception 'Не найден INTERNAL_PUSH_TOKEN: нет задания pg_cron clarify-check-due-tasks или в нём другой формат заголовков';
  end if;
end $$;

create or replace function private.notify_event_webhook()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  token text;
begin
  select value into token from private.app_secrets where name = 'internal_push_token';
  if token is null then
    return null;
  end if;

  perform net.http_post(
    url := 'https://laghxzqqgxhspwcbbcml.supabase.co/functions/v1/api/internal/notify-event',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Internal-Token', token),
    body := jsonb_build_object(
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end
    ),
    timeout_milliseconds := 5000
  );
  return null;
end;
$$;

revoke all on function private.notify_event_webhook() from public, anon, authenticated;

-- Старые триггеры на Render. Имя "Messages " — с пробелом на конце, так его
-- создала панель Supabase.
drop trigger if exists "Messages " on public.messages;
drop trigger if exists "Tasks" on public.tasks;
drop trigger if exists "Workspace_messages" on public.workspace_messages;

drop trigger if exists notify_event_messages on public.messages;
create trigger notify_event_messages
  after insert on public.messages
  for each row execute function private.notify_event_webhook();

drop trigger if exists notify_event_workspace_messages on public.workspace_messages;
create trigger notify_event_workspace_messages
  after insert on public.workspace_messages
  for each row execute function private.notify_event_webhook();

drop trigger if exists notify_event_task_assigned on public.tasks;
create trigger notify_event_task_assigned
  after update of assigned_to on public.tasks
  for each row
  when (new.assigned_to is not null and new.assigned_to is distinct from old.assigned_to)
  execute function private.notify_event_webhook();

drop trigger if exists notify_event_task_created_assigned on public.tasks;
create trigger notify_event_task_created_assigned
  after insert on public.tasks
  for each row
  when (new.assigned_to is not null and new.assigned_to is distinct from new.user_id)
  execute function private.notify_event_webhook();
