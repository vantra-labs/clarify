-- Синхронизировать токен вебхуков с заданием pg_cron.
--
-- После смены INTERNAL_PUSH_TOKEN новое значение кладут в секреты функции и в
-- задания pg_cron. Третья копия — private.app_secrets, её читают триггеры
-- уведомлений (миграция 20261031210000). Этот файл переписывает её из задания
-- clarify-check-due-tasks, так что руками вставлять токен в третий раз не нужно.
-- Запускать после каждой смены токена: «Применить SQL к базе» с этим файлом.
insert into private.app_secrets (name, value)
select 'internal_push_token',
       substring(command from 'X-Internal-Token'',\s*''([^'']+)''')
from cron.job
where jobname = 'clarify-check-due-tasks'
  and substring(command from 'X-Internal-Token'',\s*''([^'']+)''') is not null
on conflict (name) do update set value = excluded.value;
