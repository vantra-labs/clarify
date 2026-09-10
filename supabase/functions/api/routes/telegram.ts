/// HTTP-маршруты Telegram-бота: выдача кода привязки, вебхук и диагностика.
import { sql } from "../../_shared/db.ts";
import { env, SUPABASE_URL } from "../../_shared/env.ts";
import { getCurrentUserId } from "../../_shared/auth.ts";
import { HttpError, json, secretMatches } from "../../_shared/http.ts";
import { requireInternalToken } from "../../_shared/internal_auth.ts";
import { withChatLock } from "../../_shared/chat_lock.ts";
import * as tg from "../../_shared/telegram.ts";
import {
  extractChatId,
  processTelegramUpdate,
  type TelegramUpdate,
} from "./telegram_handlers.ts";

/// Адрес, который регистрируется у Telegram как вебхук. Считается из адреса
/// самого проекта — отдельная переменная понадобится только если функция
/// когда-нибудь переедет за свой домен.
function publicBaseUrl(): string {
  return env("PUBLIC_BASE_URL") || `${SUPABASE_URL}/functions/v1/api`;
}

/// Общий секрет с Telegram: он присылает его в заголовке
/// X-Telegram-Bot-Api-Secret-Token на каждом апдейте, мы сверяем и отбиваем всё
/// остальное. Без этого вебхук принимал бы что угодно от кого угодно, и
/// посторонний, подставив chat_id привязанного пользователя, выполнял бы
/// действия от его имени через ИИ-ассистента.
///
/// На FastAPI при отсутствии переменной секрет генерировался на время жизни
/// процесса. Здесь так нельзя: процессов много и они не общие — у каждого
/// получился бы свой секрет, а зарегистрирован в Telegram один. Поэтому
/// переменная обязательна.
function webhookSecret(): string {
  const secret = env("TELEGRAM_WEBHOOK_SECRET");
  // Именно 500 с внятным текстом, а не голая ошибка: «вебхук молчит» — самая
  // трудная для диагностики поломка бота, и первым делом надо видеть, что дело
  // в ненастроенном секрете, а не в Telegram.
  if (!secret) throw new HttpError(500, "TELEGRAM_WEBHOOK_SECRET не настроен");
  return secret;
}

/// Фоновая обработка после ответа Telegram.
///
/// waitUntil — то, чем в этой среде заменяются BackgroundTasks из FastAPI:
/// платформа не гасит экземпляр, пока переданная работа не закончится. Если
/// вдруг его нет (локальный запуск другой версии рантайма), честно ждём
/// обработку прямо в запросе: медленнее и рискуем повтором от Telegram, но не
/// теряем сообщение молча.
async function runInBackground(work: Promise<unknown>): Promise<void> {
  const runtime = (globalThis as {
    EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void };
  }).EdgeRuntime;
  if (runtime?.waitUntil) {
    runtime.waitUntil(work);
    return;
  }
  console.warn("[telegram] EdgeRuntime.waitUntil недоступен — обрабатываю синхронно");
  await work;
}

async function processUpdateGuarded(update: TelegramUpdate): Promise<void> {
  const chatId = extractChatId(update);
  try {
    if (chatId !== undefined) {
      await withChatLock(chatId, () => processTelegramUpdate(update));
    } else {
      await processTelegramUpdate(update);
    }
  } catch (e) {
    // Без этого необработанная ошибка в фоне тихо осела бы в логах, никак не
    // связанная по смыслу с конкретным сообщением, — а пользователь видел бы
    // ПОЛНУЮ тишину навсегда, без единого намёка, что что-то пошло не так.
    console.error(`[telegram] необработанная ошибка при обработке апдейта: ${e}`);
    if (chatId !== undefined) {
      try {
        await tg.sendMessage(
          chatId,
          "Что-то пошло не так. Попробуй ещё раз через минуту.",
          tg.withMenuButton(),
        );
      } catch {
        // Если и это не отправилось — писать больше некуда.
      }
    }
  }
}

/// Отвечаем Telegram СРАЗУ, всю обработку (в том числе вызов ИИ на 10-30+
/// секунд) уводим в фон. Раньше вебхук ждал полного завершения пайплайна перед
/// ответом — если это дольше таймаута Telegram, он засчитывает доставку как
/// неудачную и повторяет ТО ЖЕ сообщение заново, хотя обработка всё равно шла и
/// в итоге дублировалась. Именно так набиралась застрявшая очередь.
export async function telegramWebhook(req: Request): Promise<Response> {
  if (!secretMatches(req.headers.get("x-telegram-bot-api-secret-token"), webhookSecret())) {
    throw new HttpError(403, "Недействительный секрет вебхука");
  }
  const update = await req.json().catch(() => null);
  if (update === null) throw new HttpError(422, "Тело запроса не разобралось как JSON");

  await runInBackground(processUpdateGuarded(update as TelegramUpdate));
  return json(req, { ok: true });
}

/// Один активный код на пользователя — старый удаляем перед выдачей нового,
/// чтобы в таблице не копились неиспользованные хвосты. Код СОЗНАТЕЛЬНО
/// отдельный от friend_code: разный уровень риска при утечке.
export async function telegramLinkCode(req: Request): Promise<Response> {
  const userId = await getCurrentUserId(req);

  await sql`delete from telegram_link_codes where user_id = ${userId}`;
  const code = tg.generateLinkCode();
  await sql`insert into telegram_link_codes ${sql({ code, user_id: userId })}`;

  // Deep link открывает Telegram и сам подставляет «/start КОД» — печатать
  // команду руками не нужно. Без TELEGRAM_BOT_USERNAME ссылку не показываем,
  // только код: клиент в этом случае покажет инструкцию.
  const botUsername = env("TELEGRAM_BOT_USERNAME");
  return json(req, {
    code,
    deep_link: botUsername ? `https://t.me/${botUsername}?start=${code}` : null,
  });
}

/// Что Telegram реально думает о нашем вебхуке ПРЯМО СЕЙЧАС (url,
/// pending_update_count, last_error_message) — без ожидания редеплоя и чтения
/// логов. Не отдаёт ничего чувствительнее самого факта, какой URL сейчас
/// зарегистрирован: тот же уровень публичности, что и /health.
export async function telegramWebhookInfo(req: Request): Promise<Response> {
  if (!tg.TELEGRAM_BOT_TOKEN) return json(req, { error: "TELEGRAM_BOT_TOKEN не настроен" });
  return json(req, await tg.getWebhookInfo());
}

/// Диагностика «TELEGRAM_SUPPORT_CHAT_ID указывает не туда» без прогона всего
/// сценария поддержки через реального пользователя: шлёт тестовое сообщение
/// напрямую и отдаёт сырой ответ Telegram.
export async function telegramTestSupportChat(req: Request): Promise<Response> {
  requireInternalToken(req);
  if (!tg.SUPPORT_CHAT_ID) return json(req, { error: "TELEGRAM_SUPPORT_CHAT_ID не настроен" });

  const messageId = await tg.sendMessage(tg.SUPPORT_CHAT_ID, "🔧 Тестовое сообщение диагностики");
  return json(req, {
    configured_chat_id: tg.SUPPORT_CHAT_ID,
    sent: messageId !== null,
    message_id: messageId,
  });
}

/// Регистрация вебхука и профиля бота.
///
/// На FastAPI это происходило само при старте процесса. У функций старта нет,
/// поэтому вызывается вручную: один раз после переезда и дальше — если нужно
/// сбросить накопившуюся очередь недоставленных апдейтов, когда она застряла и
/// продолжает ретраить старые сообщения поверх новых.
export async function telegramResetWebhook(req: Request): Promise<Response> {
  requireInternalToken(req);
  if (!tg.TELEGRAM_BOT_TOKEN) throw new HttpError(500, "TELEGRAM_BOT_TOKEN не настроен");

  const url = `${publicBaseUrl()}/telegram/webhook`;
  const result = await tg.setWebhook(url, webhookSecret(), true);
  await tg.configureBotProfile();

  return json(req, { ok: result.status === 200, url, telegram_response: result.body });
}
