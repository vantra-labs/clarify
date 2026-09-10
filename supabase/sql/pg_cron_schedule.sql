-- Расписание служебных задач бэкенда — внутри самой базы.
--
-- Зачем это здесь, а не во внешнем сервисе. Раньше три служебных маршрута
-- дёргал воркфлоу GitHub Actions по расписанию "*/5 * * * *". На бесплатном
-- тарифе Actions расписание не соблюдает: живая проверка 05.09.2026 показала
-- запуски раз в 2-4 часа (замеры 01:18 и 05:52, между ними ничего). Из-за
-- этого напоминания о дедлайнах приходили когда придётся, а утренняя сводка
-- 05.09.2026 не пришла вообще. pg_cron живёт в самой базе и расписание
-- соблюдает.
--
-- Применяется вручную через SQL Editor в панели Supabase — как и остальной SQL
-- этого проекта (см. CLAUDE.md).
--
-- ВАЖНО: <INTERNAL_PUSH_TOKEN> ниже надо заменить на реальное значение секрета
-- функции. Готовый к вставке файл с подставленным токеном передавался отдельно,
-- в репозиторий он не кладётся.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Напоминания о дедлайнах. Каждые пять минут: это единственный маршрут, где
-- задержка видна человеку — будильник «за час до» должен приходить за час, а не
-- когда получится.
select cron.schedule(
  'clarify-check-due-tasks',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://laghxzqqgxhspwcbbcml.supabase.co/functions/v1/api/internal/check-due-tasks',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Internal-Token', '<INTERNAL_PUSH_TOKEN>'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);

-- Утренняя сводка. Раз в час, а не раз в пять минут: маршрут сам проверяет,
-- попал ли текущий момент в окно после MORNING_DIGEST_HOUR_UTC, а окно это
-- шестичасовое — ежечасного тика хватает с запасом. От повторов защищает дедуп
-- по дню (telegram_digest_sent), а не частота вызовов.
select cron.schedule(
  'clarify-morning-digest',
  '7 * * * *',
  $$
  select net.http_post(
    url := 'https://laghxzqqgxhspwcbbcml.supabase.co/functions/v1/api/internal/send-morning-digest',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Internal-Token', '<INTERNAL_PUSH_TOKEN>'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);

-- Очистка корзины. Раз в сутки: тридцатидневный срок хранения не станет точнее
-- от того, что мы будем проверять его каждые пять минут.
select cron.schedule(
  'clarify-purge-trash',
  '17 3 * * *',
  $$
  select net.http_post(
    url := 'https://laghxzqqgxhspwcbbcml.supabase.co/functions/v1/api/internal/purge-trash',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Internal-Token', '<INTERNAL_PUSH_TOKEN>'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);

-- Проверить, что задания встали:
--   select jobid, jobname, schedule, active from cron.job order by jobname;
-- Посмотреть последние запуски и их статус:
--   select jobid, status, return_message, start_time
--   from cron.job_run_details order by start_time desc limit 20;
-- Ответы самих HTTP-вызовов (pg_net отвечает асинхронно):
--   select id, status_code, content, created from net._http_response
--   order by created desc limit 20;
--
-- Снять расписание, если понадобится:
--   select cron.unschedule('clarify-check-due-tasks');
