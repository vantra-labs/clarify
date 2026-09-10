/// HTTP-обвязка роутера: CORS, ответы, ошибки.
///
/// Повторяет поведение FastAPI-бэкенда, который эти функции заменяют, — не
/// потому что «так было», а потому что клиент уже написан под него: коды
/// ответов и поле detail разбираются в main.dart (см. _sendCodeToFastAPI —
/// он показывает пользователю код ответа) и в task_service.
import { env } from "./env.ts";

/// Продакшн-домены — через ALLOWED_ORIGINS (через запятую). localhost разрешён
/// всегда по регулярке: `flutter run -d chrome` и локальная проверка веб-сборки
/// поднимаются на случайном порту. Десктоп-приложение не браузер и Origin не
/// шлёт — CORS на него не влияет вовсе.
const ALLOWED_ORIGINS = env("ALLOWED_ORIGINS")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);
const LOCALHOST_ORIGIN = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

function isAllowedOrigin(origin: string): boolean {
  return ALLOWED_ORIGINS.includes(origin) || LOCALHOST_ORIGIN.test(origin);
}

/// Заголовки CORS для конкретного запроса.
///
/// Origin возвращается ровно тот, что пришёл, а не "*": вместе с
/// Allow-Credentials звёздочка запрещена спецификацией, и браузер молча
/// отбросит ответ. Ровно так было настроено и на FastAPI (allow_credentials=True).
export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  if (!origin || !isAllowedOrigin(origin)) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Credentials": "true",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    // Клиент шлёт Authorization и Content-Type, Telegram — свой секретный
    // заголовок, планировщик — X-Internal-Token. Перечислены явно: список
    // заголовков в ответе на preflight не поддерживает "*" в старых браузерах.
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-internal-token, x-telegram-bot-api-secret-token",
    "Access-Control-Max-Age": "86400",
  };
}

export function json(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), "Content-Type": "application/json" },
  });
}

/// Аналог FastAPI HTTPException: тело {"detail": "..."} с нужным кодом.
/// Клиент разбирает именно эту форму, менять её нельзя.
export class HttpError extends Error {
  constructor(readonly status: number, readonly detail: string) {
    super(detail);
  }
}

export function errorResponse(req: Request, err: unknown): Response {
  if (err instanceof HttpError) {
    return json(req, { detail: err.detail }, err.status);
  }
  // Наружу — без подробностей: текст необработанного исключения может нести
  // фрагменты запроса к базе или ключей. В логи функции — полностью.
  console.error("[api] Необработанная ошибка:", err);
  return json(req, { detail: "Внутренняя ошибка сервера" }, 500);
}

export function preflight(req: Request): Response {
  return new Response(null, { status: 204, headers: corsHeaders(req) });
}

/// Сравнение секретов постоянным временем.
///
/// В байтах, а не в строках, и с обязательной проверкой длины: без неё сравнение
/// выходит из цикла на первом же расхождении длин и перестаёт быть
/// постоянным по времени.
export function secretMatches(got: string | null, expected: string): boolean {
  const a = new TextEncoder().encode(got ?? "");
  const b = new TextEncoder().encode(expected);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
