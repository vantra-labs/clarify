/// Обёртки над Telegram Bot API и всё, что бот показывает: меню, кнопки, тексты.
///
/// Токен бота заводится вручную через @BotFather и лежит в секретах функции
/// (TELEGRAM_BOT_TOKEN).
import { env } from "./env.ts";

const TELEGRAM_API_BASE = "https://api.telegram.org";

export const TELEGRAM_BOT_TOKEN = env("TELEGRAM_BOT_TOKEN");

/// Куда пересылать сообщения из /support — обычный Telegram chat_id
/// разработчика (не привязка через telegram_links, это просто адрес назначения
/// для пересылки, не аккаунт приложения).
export const SUPPORT_CHAT_ID = env("TELEGRAM_SUPPORT_CHAT_ID");

export type InlineKeyboard = { inline_keyboard: Array<Array<Record<string, string>>> };

function apiUrl(method: string): string {
  return `${TELEGRAM_API_BASE}/bot${TELEGRAM_BOT_TOKEN}/${method}`;
}

async function callApi(method: string, payload: unknown, timeoutMs = 10_000): Promise<Response> {
  return await fetch(apiUrl(method), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(timeoutMs),
  });
}

/// Возвращает message_id отправленного сообщения — нужен, чтобы потом
/// превратить это же сообщение («🤔 Думаю...») в готовый ответ через
/// editMessageText, а не слать два отдельных сообщения подряд.
export async function sendMessage(
  chatId: string | number,
  text: string,
  replyMarkup?: InlineKeyboard | null,
): Promise<number | null> {
  const payload: Record<string, unknown> = { chat_id: chatId, text };
  if (replyMarkup) payload.reply_markup = replyMarkup;

  const resp = await callApi("sendMessage", payload);
  // Ошибку Telegram (400/403 — например бот не может писать первым тому, кто ни
  // разу не жал /start) раньше проглатывали молча: вебхук всё равно отвечал 200,
  // а пользователь не получал ничего и без единой зацепки в логах.
  if (resp.status !== 200) {
    console.warn(`[telegram] sendMessage не удался (${resp.status}): ${(await resp.text()).slice(0, 300)}`);
    return null;
  }
  const data = await resp.json().catch(() => null);
  return data?.result?.message_id ?? null;
}

export async function editMessageText(
  chatId: string | number,
  messageId: number,
  text: string,
  replyMarkup?: InlineKeyboard | null,
): Promise<void> {
  const payload: Record<string, unknown> = { chat_id: chatId, message_id: messageId, text };
  if (replyMarkup !== undefined && replyMarkup !== null) payload.reply_markup = replyMarkup;

  const resp = await callApi("editMessageText", payload);
  if (resp.status !== 200) {
    console.warn(`[telegram] editMessageText не удался (${resp.status}): ${(await resp.text()).slice(0, 300)}`);
  }
}

export async function answerCallbackQuery(callbackQueryId: string, text?: string): Promise<void> {
  const payload: Record<string, unknown> = { callback_query_id: callbackQueryId };
  if (text) payload.text = text;
  await callApi("answerCallbackQuery", payload);
}

/// После нажатия «✅ Готово» убираем кнопку из уже отправленного напоминания —
/// иначе по одному и тому же сообщению можно нажимать сколько угодно раз.
/// {"inline_keyboard": []} — задокументированный способ очистить клавиатуру;
/// голый {} не гарантированно распознаётся как валидный пустой markup.
export async function editMessageReplyMarkup(
  chatId: string | number,
  messageId: number,
  replyMarkup: InlineKeyboard | null,
): Promise<void> {
  await callApi("editMessageReplyMarkup", {
    chat_id: chatId,
    message_id: messageId,
    reply_markup: replyMarkup ?? { inline_keyboard: [] },
  });
}

export function doneButtonMarkup(taskId: number | string): InlineKeyboard {
  return { inline_keyboard: [[{ text: "✅ Готово", callback_data: `done:${taskId}` }]] };
}

/// Меню — инлайн-кнопки, прикреплённые к КОНКРЕТНОМУ сообщению (не
/// ReplyKeyboardMarkup, замещающая клавиатуру телефона снизу). Нажатие
/// приходит как callback_query с этим callback_data, а не обычным текстом.
export const MENU_TODAY = "menu:today";
export const MENU_ALL = "menu:all";
export const MENU_HOW_IT_WORKS = "menu:how_it_works";
export const MENU_LINK_ACCOUNT = "menu:link";
export const MENU_HELP = "menu:help";
export const MENU_ASK_BOT = "menu:ask_bot";
export const MENU_SUPPORT = "menu:support";
export const MENU_ANSWERS = "menu:answers";
export const MENU_BACK = "menu:back";
export const MENU_OPEN = "menu:open";

export const MENU_TEXT = "🗂 Меню";
export const HELP_MENU_TEXT = "❓ Помощь";

export const HOW_IT_WORKS_TEXT = [
  "Как это работает:",
  "1. Напиши или отправь голосовое сообщение с задачей.",
  "2. Я распознаю задачу, добавлю в твой календарь и отчитаюсь о добавлении.",
  "3. Я умею редактировать и удалять задачи, только попроси.",
  "4. Я вижу все твои задачи, добавленные в приложении. Можешь задать мне любой " +
  "вопрос про твой личный список дел — и я дам тебе полную справку.",
].join("\n");

export function mainMenuInlineKeyboard(): InlineKeyboard {
  return {
    inline_keyboard: [
      [{ text: "🗓 Задачи на сегодня", callback_data: MENU_TODAY }],
      [{ text: "🧾 Все задачи", callback_data: MENU_ALL }],
      [{ text: "💡 Как это работает?", callback_data: MENU_HOW_IT_WORKS }],
      [
        { text: "🔗 Привязать аккаунт", callback_data: MENU_LINK_ACCOUNT },
        { text: "❓ Помощь", callback_data: MENU_HELP },
      ],
    ],
  };
}

export function helpMenuInlineKeyboard(): InlineKeyboard {
  return {
    inline_keyboard: [
      [
        { text: "🤖 Спросить у бота", callback_data: MENU_ASK_BOT },
        { text: "📩 Поддержка", callback_data: MENU_SUPPORT },
      ],
      [
        { text: "📬 Ответы", callback_data: MENU_ANSWERS },
        { text: "⬅️ Назад", callback_data: MENU_BACK },
      ],
    ],
  };
}

/// Добавляет строку с кнопкой открытия меню под любую другую клавиатуру (или
/// создаёт клавиатуру только с этой кнопкой) — чтобы из любого сообщения бота
/// можно было открыть меню, не пролистывая чат в поисках последнего меню.
export function withMenuButton(replyMarkup?: InlineKeyboard | null): InlineKeyboard {
  const keyboard = replyMarkup ? [...replyMarkup.inline_keyboard] : [];
  keyboard.push([{ text: "🗂 Открыть меню", callback_data: MENU_OPEN }]);
  return { inline_keyboard: keyboard };
}

/// Под карточкой созданной или изменённой ботом задачи. В отличие от удаления
/// по свободному тексту (сознательно не поддержано в ассистенте — риск промаха
/// маленькой бесплатной модели), нажатие конкретной кнопки под конкретной
/// задачей однозначно и безопасно, подтверждение не нужно.
export function taskActionButtons(taskId: number | string): InlineKeyboard {
  return {
    inline_keyboard: [[
      { text: "✏️ Редактировать", callback_data: `edit:${taskId}` },
      { text: "🗑 Удалить", callback_data: `delete:${taskId}` },
    ]],
  };
}

export async function downloadVoiceOgg(fileId: string): Promise<Uint8Array> {
  const infoResp = await fetch(
    `${apiUrl("getFile")}?file_id=${encodeURIComponent(fileId)}`,
    { signal: AbortSignal.timeout(15_000) },
  );
  const filePath = (await infoResp.json())?.result?.file_path;
  if (!filePath) throw new Error("Telegram не вернул путь к файлу голосового");

  const fileResp = await fetch(
    `${TELEGRAM_API_BASE}/file/bot${TELEGRAM_BOT_TOKEN}/${filePath}`,
    { signal: AbortSignal.timeout(30_000) },
  );
  return new Uint8Array(await fileResp.arrayBuffer());
}

/// Короткоживущий код привязки. 8 символов из urlsafe-алфавита: код живёт
/// считанные минуты и вводится один раз через /start, а не руками каждый день,
/// как обычный пароль.
export function generateLinkCode(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/// Текст, который Telegram показывает в ПУСТОМ чате с ботом (до первого
/// сообщения) — то, что раньше настраивалось вручную через @BotFather.
const BOT_DESCRIPTION = [
  "Clarify bot — ИИ-ассистент для планирования.",
  "",
  "Как начать?",
  "- Перейди в приложение «Clarify» и зарегистрируйся",
  "- Перейди в настройки → Telegram-бот → Получить код → открыть в Telegram",
  "",
  "После этого можно пользоваться всеми функциями бота. Приятного планирования!",
].join("\n");

/// Список команд для автокомплита по «/». "all" не может быть кириллическим
/// (Bot API требует [a-z0-9_]), поэтому в меню только "/all" — сам обработчик
/// принимает и «/все» тоже.
const BOT_COMMANDS = [
  { command: "start", description: "Привязать аккаунт по коду" },
  { command: "menu", description: "Открыть меню" },
  { command: "today", description: "Задачи на сегодня" },
  { command: "all", description: "Все задачи" },
  { command: "support", description: "Написать в поддержку" },
];

export async function configureBotProfile(): Promise<void> {
  if (!TELEGRAM_BOT_TOKEN) return;
  try {
    await callApi("setMyDescription", { description: BOT_DESCRIPTION });
    await callApi("setMyCommands", { commands: BOT_COMMANDS });
  } catch (e) {
    console.warn(`[telegram] не удалось настроить профиль бота: ${e}`);
  }
}

/// Регистрация вебхука.
///
/// На FastAPI это делалось само при старте процесса. У функций старта нет —
/// вызывается вручную через POST /telegram/reset-webhook (защищён внутренним
/// токеном) один раз после деплоя и после каждой смены адреса.
///
/// Ответ Telegram проверяется: setWebhook может вернуть 400 (невалидный токен,
/// URL не прошёл их проверку), и без проверки это никак не всплывало бы —
/// сообщения из настоящего Telegram просто никогда не долетали бы, а прямые
/// запросы к самому вебхуку выглядели бы рабочими.
export async function setWebhook(
  url: string,
  secretToken: string,
  dropPendingUpdates = false,
): Promise<{ status: number; body: string }> {
  const resp = await callApi("setWebhook", {
    url,
    drop_pending_updates: dropPendingUpdates,
    secret_token: secretToken,
  });
  const body = (await resp.text()).slice(0, 300);
  console.log(`[telegram] setWebhook(${url}) -> ${resp.status}: ${body}`);
  return { status: resp.status, body };
}

export async function getWebhookInfo(): Promise<unknown> {
  const resp = await fetch(apiUrl("getWebhookInfo"), { signal: AbortSignal.timeout(10_000) });
  return await resp.json();
}
