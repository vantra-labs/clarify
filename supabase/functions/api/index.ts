/// Бэкенд Clarify.
///
/// Раньше это был FastAPI на Render. Переехало сюда 08.09.2026, потому что
/// адреса Render (216.24.57.0/24) перестали открываться из России: приложение
/// не пускало людей внутрь, хотя сам Supabase был доступен. Проверено с
/// телефона без VPN — голый IP тоже висит, значит режут не имя, и никакой
/// свой домен поверх Render не помог бы.
///
/// Всё живёт одной функцией с роутингом по пути, а не десятком отдельных
/// функций: у клиента один базовый адрес (AppConfig.backendBaseUrl), общий
/// код (ассистент, обёртки Telegram, доступ к базе) не размазан по копиям, и
/// деплой один.
import { corsHeaders, errorResponse, json, preflight } from "../_shared/http.ts";
import { latestRelease } from "../_shared/latest_release.ts";
import { authYandex } from "./routes/auth_yandex.ts";
import { mcpRoute } from "./routes/mcp.ts";
import { tasksParse } from "./routes/tasks_parse.ts";
import { transcribeVoiceRoute } from "./routes/transcribe_voice.ts";
import {
  checkDueTasks,
  notifyEvent,
  purgeTrash,
  sendMorningDigest,
} from "./routes/internal.ts";
import {
  telegramLinkCode,
  telegramResetWebhook,
  telegramTestSupportChat,
  telegramWebhook,
  telegramWebhookInfo,
} from "./routes/telegram.ts";

type Handler = (req: Request) => Promise<Response> | Response;

/// Путь внутри функции. Supabase отдаёт сюда полный путь запроса вместе с
/// именем функции ("/api/health"), а при локальном запуске — ещё и с
/// префиксом "/functions/v1". Снимаем и то, и другое, чтобы таблица маршрутов
/// совпадала с путями старого FastAPI один в один.
function routePath(req: Request): string {
  let path = new URL(req.url).pathname;
  if (path.startsWith("/functions/v1")) path = path.slice("/functions/v1".length);
  if (path.startsWith("/api")) path = path.slice("/api".length);
  if (path.length > 1 && path.endsWith("/")) path = path.slice(0, -1);
  return path || "/";
}

const ROUTES: Record<string, Partial<Record<string, Handler>>> = {
  "/health": {
    GET: (req) => json(req, { status: "ok" }),
  },

  "/app/latest-version": {
    // Какая версия десктопного приложения сейчас актуальна: последний релиз
    // в GitHub, секреты функции — запасной вариант (см. _shared/latest_release.ts).
    //
    // Пустая version означает «обновлений нет», и клиент в этом случае обязан
    // молчать, а не показывать «версия неизвестна» (см. update_service.dart).
    GET: async (req) => json(req, await latestRelease()),
  },

  "/auth/yandex": {
    POST: authYandex,
  },

  "/tasks/parse": {
    POST: tasksParse,
  },

  "/ai/transcribe-voice": {
    POST: transcribeVoiceRoute,
  },

  "/telegram/link-code": {
    POST: telegramLinkCode,
  },
  "/telegram/webhook": {
    POST: telegramWebhook,
  },
  "/telegram/webhook-info": {
    GET: telegramWebhookInfo,
  },
  "/telegram/test-support-chat": {
    GET: telegramTestSupportChat,
  },
  "/telegram/reset-webhook": {
    POST: telegramResetWebhook,
  },

  "/internal/check-due-tasks": {
    POST: checkDueTasks,
  },
  "/internal/send-morning-digest": {
    POST: sendMorningDigest,
  },
  "/internal/purge-trash": {
    POST: purgeTrash,
  },
  "/internal/notify-event": {
    POST: notifyEvent,
  },

  // MCP-сервера здесь нет намеренно: у него путь с переменной частью
  // (/mcp/<ключ>), а таблица маршрутов сравнивает путь целиком. Он разбирается
  // до неё, см. Deno.serve ниже.
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);

  const path = routePath(req);

  // Ключ подключения может стоять прямо в адресе (/mcp/<ключ>) — часть
  // MCP-клиентов умеет только вставить ссылку и не даёт задать заголовки.
  // Разбирает его сам маршрут, роутеру достаточно узнать путь.
  if (path === "/mcp" || path.startsWith("/mcp/")) {
    try {
      return await mcpRoute(req);
    } catch (e) {
      return errorResponse(req, e);
    }
  }

  const methods = ROUTES[path];
  if (!methods) {
    return json(req, { detail: `Неизвестный путь: ${path}` }, 404);
  }
  const handler = methods[req.method];
  if (!handler) {
    return new Response(JSON.stringify({ detail: "Метод не поддерживается" }), {
      status: 405,
      headers: {
        ...corsHeaders(req),
        "Content-Type": "application/json",
        Allow: Object.keys(methods).join(", "),
      },
    });
  }

  try {
    return await handler(req);
  } catch (e) {
    return errorResponse(req, e);
  }
});
