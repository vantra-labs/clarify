/// Обработка апдейтов Telegram-бота.
///
/// Порт того же кода с FastAPI. Отличие одно и вынужденное: там обработка
/// уходила в BackgroundTasks одного процесса, здесь — в EdgeRuntime.waitUntil,
/// а сериализация сообщений одного чата держится не на замке в памяти, а на
/// консультативной блокировке Postgres (см. chat_lock.ts).
import { notDeleted, sql } from "../../_shared/db.ts";
import { runAssistant } from "../../_shared/ai_parser.ts";
import { transcribeVoice } from "../../_shared/groq.ts";
import { getProfileName } from "../../_shared/profiles.ts";
import {
  executeAssistantActions,
  fetchExistingTasksForAssistant,
  type TaskRow,
} from "../../_shared/tasks.ts";
import * as tg from "../../_shared/telegram.ts";

/// Сколько живёт код привязки. Он вводится сразу после получения в приложении,
/// а долгоживущий код — это долгоживущий доступ к чужим задачам.
const LINK_CODE_TTL_MS = 15 * 60 * 1000;

const PRIORITY_LABELS: Record<string, string> = {
  red: "🔴 Срочный",
  orange: "🟠 Важный",
  blue: "🔵 Обычный",
  gray: "⚪ Низкий",
};

/// Сколько последних вопросов в поддержку показывать в разделе «Ответы».
const ANSWERS_LIMIT = 10;

const NOT_LINKED_TEXT = "Сначала привяжи аккаунт: /start КОД (код — в настройках приложения)";

interface TelegramMessage {
  chat: { id: number | string };
  text?: string;
  voice?: { file_id: string };
  reply_to_message?: { message_id: number };
}

interface TelegramCallbackQuery {
  id: string;
  data?: string;
  message?: { message_id?: number; chat?: { id?: number | string } };
}

export interface TelegramUpdate {
  message?: TelegramMessage;
  callback_query?: TelegramCallbackQuery;
}

async function getLinkedUserId(chatId: string | number): Promise<string | null> {
  const [link] = await sql<{ user_id: string }[]>`
    select user_id from telegram_links where telegram_chat_id = ${String(chatId)} limit 1
  `;
  return link?.user_id ?? null;
}

/// Отправляет главное меню НОВЫМ сообщением и гасит кнопки у предыдущего
/// открытого меню в этом чате — чтобы в чате всегда было видно только одно
/// живое меню, а не по копии на каждый /menu.
async function openMenuMessage(chatId: string | number, text: string): Promise<void> {
  const key = String(chatId);
  const [prev] = await sql<{ message_id: number }[]>`
    select message_id from telegram_menu_messages where telegram_chat_id = ${key} limit 1
  `;
  if (prev) {
    try {
      await tg.editMessageReplyMarkup(chatId, prev.message_id, tg.withMenuButton());
    } catch {
      // Старое сообщение могло быть удалено пользователем или устареть для
      // редактирования — не критично, само меню всё равно откроется.
    }
  }

  const newId = await tg.sendMessage(chatId, text, tg.mainMenuInlineKeyboard());
  if (newId === null) return;

  if (prev) {
    await sql`update telegram_menu_messages set message_id = ${newId} where telegram_chat_id = ${key}`;
  } else {
    await sql`insert into telegram_menu_messages ${sql({ telegram_chat_id: key, message_id: newId })}`;
  }
}

async function handleStart(chatId: string | number, text: string): Promise<void> {
  // Всё после первого пробела — это код. Именно так, а не split с лимитом:
  // в JS лимит у split ОТБРАСЫВАЕТ хвост, а не оставляет его вторым куском,
  // как maxsplit в Python.
  const spaceIndex = text.search(/\s/);
  const code = spaceIndex === -1 ? "" : text.slice(spaceIndex + 1).trim();

  if (!code) {
    // Голый /start у УЖЕ привязанного чата — не показываем «привяжи аккаунт»
    // (сбивает с толку), а заново присылаем меню: это единственный способ
    // показать клавиатуру тому, кто привязался ДО того, как меню появилось.
    if (await getLinkedUserId(chatId)) {
      await openMenuMessage(chatId, "Аккаунт уже привязан 🎉\n\n" + tg.MENU_TEXT);
      return;
    }
    await tg.sendMessage(
      chatId,
      "Привет! Чтобы привязать аккаунт, получи код в приложении (Настройки → Telegram-бот) и напиши мне /start КОД",
      tg.withMenuButton(),
    );
    return;
  }

  const [linkCode] = await sql<{ code: string; user_id: string; created_at: Date }[]>`
    select code, user_id, created_at from telegram_link_codes where code = ${code} limit 1
  `;
  const expired = linkCode !== undefined &&
    Date.now() - new Date(linkCode.created_at).getTime() > LINK_CODE_TTL_MS;

  if (!linkCode || expired) {
    if (linkCode) await sql`delete from telegram_link_codes where code = ${code}`;
    await tg.sendMessage(
      chatId,
      "Код неверный или устарел. Сгенерируй новый в приложении.",
      tg.withMenuButton(),
    );
    return;
  }

  // Снимаем и старую привязку этого пользователя (если раньше привязывал
  // другой чат), и старую привязку ИМЕННО этого чата (если раньше был привязан
  // к другому аккаунту) — telegram_chat_id первичный ключ, иначе конфликт.
  const key = String(chatId);
  await sql`
    delete from telegram_links
    where user_id = ${linkCode.user_id} or telegram_chat_id = ${key}
  `;
  await sql`insert into telegram_links ${sql({ telegram_chat_id: key, user_id: linkCode.user_id })}`;
  await sql`delete from telegram_link_codes where code = ${code}`;

  await openMenuMessage(
    chatId,
    "Готово! Аккаунт привязан 🎉 Пиши или надиктовывай задачи прямо сюда — или пользуйся меню ниже.\n\n" +
      tg.MENU_TEXT,
  );
}

function checklistStats(checklist: unknown): [number, number] | null {
  if (!Array.isArray(checklist) || checklist.length === 0) return null;
  const done = checklist.filter(
    (item) => typeof item === "object" && item !== null &&
      (item as { done?: unknown }).done === true,
  ).length;
  return [done, checklist.length];
}

/// Один блок на одну задачу — переиспользуется и для /today, /все (каждая
/// задача отдельным сообщением), и для карточки создания/правки (свой header).
function formatTaskDetail(
  t: {
    title: string | null;
    due_date: string | null;
    due_time: string | null;
    priority: string | null;
    tags: string | null;
    note: string | null;
    checklist: unknown;
  },
  header?: string,
): string {
  const lines = [header ?? `📌 ${t.title}`];
  if (t.due_date) {
    let line = `📅 ${t.due_date}`;
    if (t.due_time) line += ` в ${t.due_time}`;
    lines.push(line);
  }
  const label = t.priority ? PRIORITY_LABELS[t.priority] : undefined;
  if (label) lines.push(label);
  if (t.tags) lines.push(`#${t.tags}`);
  if (t.note) lines.push(`📝 ${t.note}`);
  const stats = checklistStats(t.checklist);
  if (stats) lines.push(`☑️ ${stats[0]}/${stats[1]}`);
  return lines.join("\n");
}

/// Карточку создания/правки формулирует код, а не модель: маленькие бесплатные
/// модели иногда выдают неуклюжие формулировки и не всегда перечисляют все
/// поля. Детерминированный шаблон — предсказуемый и полный список данных.
function formatTaskConfirmation(task: TaskRow, actionType: "create" | "update"): string {
  const verb = actionType === "create" ? "Добавлено" : "Изменено";
  const icon = actionType === "create" ? "✅" : "✏️";
  return formatTaskDetail(task, `${icon} ${verb}: ${task.title}`);
}

/// Сегодняшняя дата так же, как её считал прежний бэкенд — по времени сервера
/// (UTC). Часового пояса пользователя у бэкенда нет; менять это при переезде
/// нельзя, иначе «сегодня» у бота и у ассистента разъедется.
function todayString(): string {
  return new Intl.DateTimeFormat("ru-RU", {
    timeZone: "UTC",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(new Date());
}

async function handleList(
  chatId: string | number,
  userId: string,
  todayOnly: boolean,
): Promise<void> {
  let tasks = await fetchExistingTasksForAssistant(userId);
  if (todayOnly) {
    const today = todayString();
    tasks = tasks.filter((t) => t.due_date === today);
  }

  if (tasks.length === 0) {
    await tg.sendMessage(
      chatId,
      todayOnly ? "На сегодня ничего не запланировано." : "Задач пока нет.",
      tg.withMenuButton(),
    );
    return;
  }

  if (todayOnly) {
    // Обычно задач немного: отдельное сообщение на каждую (с кнопками
    // «Редактировать»/«Удалить») читается лучше и позволяет править прямо здесь.
    await tg.sendMessage(chatId, "Задачи на сегодня");
    for (const t of tasks) {
      await tg.sendMessage(
        chatId,
        formatTaskDetail(t),
        tg.withMenuButton(tg.taskActionButtons(t.id)),
      );
    }
    return;
  }

  // Задач может накопиться много (годами), отдельное сообщение на каждую забило
  // бы чат целиком. Одно сообщение со всеми, без кнопок правки — она доступна
  // через /today или через диалог с ассистентом.
  const blocks = tasks.map((t) => formatTaskDetail(t));
  await tg.sendMessage(chatId, "Все задачи\n\n" + blocks.join("\n\n"), tg.withMenuButton());
}

async function createSupportTicket(
  chatId: string | number,
  userId: string,
  question: string,
): Promise<void> {
  // forwarded_message_id — id ИМЕННО пересланного сообщения в чате поддержки.
  // Когда разработчик отвечает на него реплаем прямо в Telegram, входящий
  // апдейт несёт reply_to_message.message_id, совпадающий с этим полем — так
  // находится нужный тикет без ручной разметки с обеих сторон.
  let forwardedId: number | null = null;
  if (tg.SUPPORT_CHAT_ID) {
    const who = await getProfileName(userId);
    forwardedId = await tg.sendMessage(
      tg.SUPPORT_CHAT_ID,
      `📩 Вопрос от ${who} (chat_id=${chatId}):\n${question}`,
    );
  }

  await sql`insert into support_tickets ${
    sql({
      user_id: userId,
      telegram_chat_id: String(chatId),
      question,
      forwarded_message_id: forwardedId,
    })
  }`;

  await tg.sendMessage(
    chatId,
    "Спасибо, вопрос передан в поддержку! Ответ появится в разделе «📬 Ответы».",
    tg.withMenuButton(),
  );
}

async function handleSupportCommand(
  chatId: string | number,
  userId: string | null,
  text: string,
): Promise<void> {
  const question = text.slice("/support".length).trim();
  if (!question) {
    await tg.sendMessage(
      chatId,
      "Напиши вопрос после команды, например: /support не сохраняется задача",
      tg.withMenuButton(),
    );
    return;
  }
  if (userId === null) {
    await tg.sendMessage(chatId, NOT_LINKED_TEXT, tg.withMenuButton());
    return;
  }
  await createSupportTicket(chatId, userId, question);
}

async function handleAnswers(chatId: string | number, userId: string): Promise<void> {
  const tickets = await sql<{ question: string; answer: string | null }[]>`
    select question, answer from support_tickets
    where user_id = ${userId}
    order by created_at desc
    limit ${ANSWERS_LIMIT}
  `;
  if (tickets.length === 0) {
    await tg.sendMessage(chatId, "Вопросов в поддержку пока не было.", tg.withMenuButton());
    return;
  }
  for (const t of tickets) {
    const answerText = t.answer ? t.answer : "Ожидаем ответ от поддержки.";
    await tg.sendMessage(chatId, `❓ ${t.question}\n\n💬 ${answerText}`, tg.withMenuButton());
  }
}

async function handleMenuCallback(
  chatId: string | number,
  messageId: number | undefined,
  callbackId: string,
  menuAction: string,
): Promise<void> {
  const userId = await getLinkedUserId(chatId);

  if (menuAction === "help") {
    await tg.answerCallbackQuery(callbackId);
    if (messageId !== undefined) {
      await tg.editMessageText(chatId, messageId, tg.HELP_MENU_TEXT, tg.helpMenuInlineKeyboard());
    }
    return;
  }

  if (menuAction === "how_it_works") {
    await tg.answerCallbackQuery(callbackId);
    await tg.sendMessage(chatId, tg.HOW_IT_WORKS_TEXT, tg.withMenuButton());
    return;
  }

  if (menuAction === "back") {
    await tg.answerCallbackQuery(callbackId);
    if (messageId !== undefined) {
      await tg.editMessageText(chatId, messageId, tg.MENU_TEXT, tg.mainMenuInlineKeyboard());
    }
    return;
  }

  if (menuAction === "open") {
    // Кнопка «🗂 Открыть меню» стоит под КАЖДЫМ сообщением бота — в отличие от
    // «back», открывает меню НОВЫМ сообщением, а не редактирует то, под которым
    // нажали (иначе затёрла бы карточку задачи или ответ ассистента).
    await tg.answerCallbackQuery(callbackId);
    await openMenuMessage(chatId, tg.MENU_TEXT);
    return;
  }

  if (menuAction === "link") {
    await tg.answerCallbackQuery(callbackId);
    await tg.sendMessage(
      chatId,
      "Получи код в приложении (Настройки → Telegram-бот) и напиши мне /start КОД",
      tg.withMenuButton(),
    );
    return;
  }

  if (menuAction === "today" || menuAction === "all") {
    if (userId === null) {
      await tg.answerCallbackQuery(callbackId, "Сначала привяжи аккаунт");
      return;
    }
    await tg.answerCallbackQuery(callbackId);
    await handleList(chatId, userId, menuAction === "today");
    return;
  }

  if (menuAction === "ask_bot") {
    // Никакого особого состояния не нужно — что бы пользователь ни написал
    // следующим сообщением, оно и так пойдёт обычным путём в ассистента. Текст
    // ОТЛИЧАЕТСЯ от поддержки ниже: раньше оба показывали одинаковое «Какой у
    // вас вопрос?», и из истории чата было не понять, какой сценарий активен.
    await tg.answerCallbackQuery(callbackId);
    await tg.sendMessage(
      chatId,
      "Какой у вас вопрос к ассистенту? Пиши или надиктуй.",
      tg.withMenuButton(),
    );
    return;
  }

  if (menuAction === "support") {
    await tg.answerCallbackQuery(callbackId);
    if (userId === null) {
      await tg.sendMessage(chatId, NOT_LINKED_TEXT, tg.withMenuButton());
      return;
    }
    const key = String(chatId);
    await sql`delete from telegram_pending_support_questions where telegram_chat_id = ${key}`;
    await sql`insert into telegram_pending_support_questions ${sql({ telegram_chat_id: key })}`;
    await tg.sendMessage(
      chatId,
      "Опиши вопрос для поддержки — ответим здесь же, в разделе «📬 Ответы».",
      tg.withMenuButton(),
    );
    return;
  }

  if (menuAction === "answers") {
    await tg.answerCallbackQuery(callbackId);
    if (userId === null) {
      await tg.sendMessage(chatId, NOT_LINKED_TEXT, tg.withMenuButton());
      return;
    }
    await handleAnswers(chatId, userId);
    return;
  }

  await tg.answerCallbackQuery(callbackId);
}

async function handleCallback(callbackQuery: TelegramCallbackQuery): Promise<void> {
  const data = callbackQuery.data ?? "";
  const chatId = callbackQuery.message?.chat?.id;
  const messageId = callbackQuery.message?.message_id;
  const callbackId = callbackQuery.id;

  if (chatId === undefined || !data.includes(":")) {
    await tg.answerCallbackQuery(callbackId);
    return;
  }

  const separator = data.indexOf(":");
  const action = data.slice(0, separator);
  const rest = data.slice(separator + 1);

  if (action === "menu") {
    await handleMenuCallback(chatId, messageId, callbackId, rest);
    return;
  }

  if (action !== "done" && action !== "edit" && action !== "delete") {
    await tg.answerCallbackQuery(callbackId);
    return;
  }

  const userId = await getLinkedUserId(chatId);
  if (userId === null) {
    await tg.answerCallbackQuery(callbackId, "Аккаунт не привязан");
    return;
  }

  const taskId = Number.parseInt(rest, 10);
  if (Number.isNaN(taskId)) {
    await tg.answerCallbackQuery(callbackId, "Задача не найдена");
    return;
  }

  const [task] = await sql<TaskRow[]>`
    select * from tasks
    where id = ${taskId} and user_id = ${userId} and ${notDeleted()}
    limit 1
  `;
  if (!task) {
    await tg.answerCallbackQuery(callbackId, "Задача не найдена");
    return;
  }

  if (action === "done") {
    await sql`
      update tasks set is_completed = true, completed_at = ${new Date()} where id = ${taskId}
    `;
    await tg.answerCallbackQuery(callbackId, "Отмечено выполненным ✅");
    if (messageId !== undefined) {
      await tg.editMessageReplyMarkup(chatId, messageId, tg.withMenuButton());
    }
    return;
  }

  if (action === "delete") {
    // Кнопка под КОНКРЕТНОЙ, уже показанной задачей — в отличие от удаления по
    // свободному тексту (сознательно не поддержано в ассистенте), здесь нет
    // риска, что модель промахнётся мимо задачи: id зафиксирован в кнопке.
    await sql`delete from tasks where id = ${taskId}`;
    await tg.answerCallbackQuery(callbackId, "Удалено");
    if (messageId !== undefined) {
      await tg.editMessageText(
        chatId,
        messageId,
        `🗑 Удалено: ${task.title}`,
        tg.withMenuButton(),
      );
    }
    return;
  }

  // edit
  const key = String(chatId);
  await sql`delete from telegram_pending_edits where telegram_chat_id = ${key}`;
  await sql`insert into telegram_pending_edits ${sql({ telegram_chat_id: key, task_id: taskId })}`;
  await tg.answerCallbackQuery(callbackId);
  await tg.sendMessage(chatId, "Что хочешь изменить? Напиши или надиктуй.", tg.withMenuButton());
}

/// Разработчик отвечает В ЧАТЕ ПОДДЕРЖКИ реплаем на пересланный вопрос —
/// находим тикет по id того самого пересланного сообщения.
async function handleSupportReply(
  repliedToMessageId: number,
  answerText: string,
): Promise<void> {
  const [ticket] = await sql<
    { id: number; question: string; telegram_chat_id: string }[]
  >`
    select id, question, telegram_chat_id from support_tickets
    where forwarded_message_id = ${repliedToMessageId}
    limit 1
  `;
  if (!ticket) return;

  await sql`
    update support_tickets
    set answer = ${answerText}, answered_at = ${new Date()}
    where id = ${ticket.id}
  `;
  await tg.sendMessage(
    ticket.telegram_chat_id,
    `📬 Получен ответ от поддержки!\n\n❓ ${ticket.question}\n\n💬 ${answerText}`,
    tg.withMenuButton(),
  );
}

async function handleMessage(message: TelegramMessage): Promise<void> {
  const chatId = message.chat.id;
  let text = message.text;
  const voice = message.voice;

  // Ответ разработчика в чате поддержки — проверяем раньше всего остального:
  // это отдельный, не пользовательский чат, и обычная логика команд здесь
  // неприменима.
  const replyTo = message.reply_to_message;
  if (text && replyTo && tg.SUPPORT_CHAT_ID && String(chatId) === String(tg.SUPPORT_CHAT_ID)) {
    await handleSupportReply(replyTo.message_id, text);
    return;
  }

  if (text && text.startsWith("/start")) {
    await handleStart(chatId, text);
    return;
  }

  const userId = await getLinkedUserId(chatId);

  // Кнопки меню инлайновые и приходят как callback_query. Слэш-команды ниже
  // остаются рабочими наравне с меню — по прямой просьбе владельца.
  if (text === "/menu") {
    await openMenuMessage(chatId, tg.MENU_TEXT);
    return;
  }

  if (text === "/today" || text === "/all" || text === "/все") {
    if (userId) {
      await handleList(chatId, userId, text === "/today");
    } else {
      await tg.sendMessage(chatId, NOT_LINKED_TEXT, tg.withMenuButton());
    }
    return;
  }

  if (text && text.startsWith("/support")) {
    await handleSupportCommand(chatId, userId, text);
    return;
  }

  if (userId === null) {
    await tg.sendMessage(
      chatId,
      "Сначала привяжи аккаунт: получи код в приложении (Настройки → Telegram-бот) и напиши мне /start КОД",
      tg.withMenuButton(),
    );
    return;
  }

  // Если перед этим нажали «📩 Поддержка» — это сообщение и есть сам вопрос, а
  // не задача для ассистента. Голос здесь сознательно не обрабатываем: вопрос в
  // поддержку ждём текстом, состояние остаётся, пока не придёт настоящий текст.
  const key = String(chatId);
  const [pendingSupport] = await sql<{ telegram_chat_id: string }[]>`
    select telegram_chat_id from telegram_pending_support_questions
    where telegram_chat_id = ${key} limit 1
  `;
  if (pendingSupport) {
    if (!text) {
      await tg.sendMessage(chatId, "Напиши вопрос текстом, пожалуйста.", tg.withMenuButton());
      return;
    }
    await sql`delete from telegram_pending_support_questions where telegram_chat_id = ${key}`;
    await createSupportTicket(chatId, userId, text);
    return;
  }

  // «Думаю...» сразу после получения сообщения — раньше между сообщением и
  // ответом бота была полная тишина (разбор занимает 10-30+ секунд). Это же
  // сообщение потом ПРЕВРАЩАЕТСЯ в реальный ответ через editMessageText, а не
  // остаётся отдельным, которое пришлось бы прятать.
  const thinkingId = await tg.sendMessage(chatId, "🤔 Думаю...");

  const reply = async (text_: string, replyMarkup?: tg.InlineKeyboard | null) => {
    const markup = tg.withMenuButton(replyMarkup);
    if (thinkingId !== null) {
      await tg.editMessageText(chatId, thinkingId, text_, markup);
      return;
    }
    await tg.sendMessage(chatId, text_, markup);
  };

  if (voice) {
    try {
      const audio = await tg.downloadVoiceOgg(voice.file_id);
      text = await transcribeVoice(audio);
    } catch (e) {
      await reply(`Не удалось распознать голосовое: ${e}`);
      return;
    }
  }

  if (!text) {
    await reply("Не понял сообщение — напиши текстом или голосом.");
    return;
  }

  // Если перед этим нажали «✏️ Редактировать» — следующее сообщение это правка
  // КОНКРЕТНОЙ задачи, а не новая, независимо от формулировки. Явно называем
  // ассистенту id задачи вместо того, чтобы он угадывал его по тексту правки.
  const [pendingEdit] = await sql<{ task_id: number }[]>`
    select task_id from telegram_pending_edits where telegram_chat_id = ${key} limit 1
  `;
  let assistantText = text;
  if (pendingEdit) {
    assistantText = `Правка существующей задачи с id=${pendingEdit.task_id}: "${text}"`;
    await sql`delete from telegram_pending_edits where telegram_chat_id = ${key}`;
  }

  // История чата с ботом — отдельная от истории в самом приложении; бот пока не
  // хранит переписку между сообщениями (нет таблицы под это), поэтому история
  // пустая: ассистент всё равно видит актуальные задачи, просто не помнит
  // предыдущие сообщения именно в этом канале.
  const existingTasks = await fetchExistingTasksForAssistant(userId);
  const result = await runAssistant(assistantText, existingTasks, []);
  const affected = await executeAssistantActions(userId, result.actions, text.slice(0, 20));

  if (affected.length === 0) {
    await reply(result.reply);
    return;
  }

  // Первое действие превращает «Думаю...» в готовую карточку; остальные (если
  // ассистент выполнил несколько действий за одно сообщение) — отдельными
  // сообщениями, у каждой задачи свои кнопки.
  const [first, ...rest] = affected;
  await reply(formatTaskConfirmation(first.task, first.type), tg.taskActionButtons(first.task.id));
  for (const item of rest) {
    await tg.sendMessage(
      chatId,
      formatTaskConfirmation(item.task, item.type),
      tg.withMenuButton(tg.taskActionButtons(item.task.id)),
    );
  }
}

export function extractChatId(update: TelegramUpdate): string | number | undefined {
  if (update.callback_query) return update.callback_query.message?.chat?.id;
  return update.message?.chat?.id;
}

export async function processTelegramUpdate(update: TelegramUpdate): Promise<void> {
  if (update.callback_query) {
    await handleCallback(update.callback_query);
    return;
  }
  if (update.message) {
    await handleMessage(update.message);
  }
}
