/// Доступ к переменным окружения функции.
///
/// trim() здесь не косметика, а перенесённый урок с Render (см. latest_version
/// в старом main.py): значения вставляют руками в панель, и перевод строки на
/// конце попадает туда незаметно — URL с "\n" перестаёт быть ссылкой. Чинить
/// это на стороне потребителя неправильно: потребителей много, а место, где
/// значение портится, одно.
export function env(name: string): string {
  return (Deno.env.get(name) ?? "").trim();
}

/// Обязательная переменная. Бросает, а не возвращает пустую строку: молча
/// работающая без ключа функция отдаёт 200 и пустой результат, и разбираться
/// потом не в чем.
export function requireEnv(name: string): string {
  const value = env(name);
  if (!value) throw new Error(`Переменная окружения ${name} не настроена`);
  return value;
}

export function envInt(name: string, fallback: number): number {
  const raw = env(name);
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isNaN(parsed) ? fallback : parsed;
}

/// URL и ключи самого Supabase функциям выдаёт платформа — в секреты их класть
/// не нужно. Это заодно означает, что service_role-ключ больше нигде не лежит
/// руками: раньше он копировался в переменные Render.
export const SUPABASE_URL = env("SUPABASE_URL");
export const SUPABASE_ANON_KEY = env("SUPABASE_ANON_KEY");
export const SUPABASE_SERVICE_ROLE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");

/// Заголовки для Supabase Admin API. Вызывать только после проверки, что ключ
/// настроен, — иначе Supabase вернёт 401, и разбираться будет не в чем.
export function supabaseAdminHeaders(): Record<string, string> {
  return {
    "apikey": SUPABASE_SERVICE_ROLE_KEY,
    "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    "Content-Type": "application/json",
  };
}
