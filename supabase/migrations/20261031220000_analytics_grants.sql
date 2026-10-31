-- Явные права на аналитику (31.10.2026).
--
-- Supabase перестаёт автоматически открывать новые таблицы для ролей API
-- (auto_expose_new_tables, см. supabase/config.toml). Этот проект создан до
-- смены правил и права по умолчанию пока получает — проверено
-- supabase/checks/analytics_insert_as_user.sql. Но опираться на это нельзя:
-- права выдаются явно. Только запись и только для вошедших; читать события
-- по-прежнему не может никто, кроме analytics_summary().
grant insert on public.analytics_events to authenticated;
revoke select, update, delete on public.analytics_events from anon, authenticated;
revoke all on public.analytics_events from anon;
revoke all on public.analytics_admins from anon, authenticated;
