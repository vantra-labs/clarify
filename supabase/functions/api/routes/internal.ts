/// Служебные маршруты: напоминания о дедлайнах, утренняя сводка, очистка
/// корзины и мгновенные уведомления о событиях в базе.
///
/// Первые три дёргаются по расписанию (см. sql/pg_cron_schedule.sql — теперь
/// изнутри самой базы, а не внешним пингером), последний — Database Webhook
/// сразу при изменении нужной таблицы.
import { notDeleted, sql } from "../../_shared/db.ts";
import {
  env,
  envInt,
  SUPABASE_URL,
  supabaseAdminHeaders,
} from "../../_shared/env.ts";
import { HttpError, json } from "../../_shared/http.ts";
import { requireInternalToken } from "../../_shared/internal_auth.ts";
import { getProfileName } from "../../_shared/profiles.ts";
import { sendWebPushToUser } from "../../_shared/push.ts";
import { parseTaskDateTime, type TaskRow } from "../../_shared/tasks.ts";
import * as tg from "../../_shared/telegram.ts";

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

/// Насколько ПОЗДНО ещё имеет смысл слать будильник, который уже наступил.
///
/// Раньше здесь было десять минут — «не уже, чем интервал пинга». Расчёт был на
/// честные */5 в GitHub Actions, но живая проверка 05.09.2026 показала: на
/// бесплатном тарифе Actions расписание не соблюдает и запускает воркфлоу раз в
/// 2-4 часа. Будильник, чей момент попал между двумя запусками, не отправлялся
/// НИКОГДА: следующий запуск видел его уже вне десятиминутного окна.
///
/// Нижняя граница не нужна для защиты от дублей — от них защищает
/// sent_push_notifications. Она нужна, только чтобы не воскрешать древние
/// будильники: 12 часов — «проспали полдня, но напомнить ещё осмысленно», а про
/// дедлайн трёхдневной давности писать уже незачем.
const CHECK_WINDOW_MS = 12 * HOUR_MS;

const ALARM_OFFSETS: Array<{ offset: number; deltaMs: number; title: string }> = [
  { offset: 1, deltaMs: 3 * DAY_MS, title: "Бро, скоро дедлайн!" },
  { offset: 2, deltaMs: DAY_MS, title: "Завтра сдавать!" },
  { offset: 3, deltaMs: HOUR_MS, title: "Время пришло!" },
  { offset: 4, deltaMs: 0, title: "Дедлайн!" },
];

/// Час утренней сводки. Часового пояса пользователя у бэкенда нет, поэтому час
/// фиксированный: 5:00 UTC = 8:00 МСК.
const MORNING_DIGEST_HOUR_UTC = envInt("MORNING_DIGEST_HOUR_UTC", 5);

/// Условие — НЕ узкое окно вокруг часа, а «первый запуск в этот день начиная с
/// целевого часа». Узкое окно не работало: 05.09.2026 сводка не пришла вообще,
/// потому что между 01:18 и 05:52 UTC запусков просто не было. От повторов
/// защищает не окно, а дедуп по дню. Верхняя граница нужна, чтобы догоняющая
/// сводка не прилетела глубокой ночью: лучше пропустить день, чем разбудить.
const DIGEST_MAX_DELAY_MS = 6 * HOUR_MS;

/// «Гниющая» задача — та же логика, что рисует бейдж в приложении: не
/// выполнена, без даты или уже просрочена, и создана дольше TASK_ROT_DAYS
/// назад. Значение обязано совпадать с AppConfig.taskRotDays на клиенте —
/// иначе в сводке и на карточке будут разные задачи, и человек решит, что одно
/// из двух врёт.
const TASK_ROT_DAYS = envInt("TASK_ROT_DAYS", 5);

/// Сколько названий перечислять в сводке. Больше — это уже не сигнал, а стена
/// текста, которую пролистывают.
const ROT_DIGEST_LIMIT = 3;

/// Тридцать дней — обещание, данное пользователю в интерфейсе корзины; без
/// уборки оно превратилось бы в «храним вечно».
const TRASH_RETENTION_DAYS = envInt("TRASH_RETENTION_DAYS", 30);

/// Аналог sendWebPushToUser, но в Telegram — только если пользователь привязал
/// бота. Надёжнее веб-пуша на мобильном (не зависит от разрешений браузера и от
/// того, жива ли подписка Service Worker), поэтому там, где уже был веб-пуш,
/// шлём ОБА канала, а не заменяем один другим.
async function sendTelegramToUser(
  userId: string | null,
  message: string,
  replyMarkup?: tg.InlineKeyboard | null,
): Promise<number> {
  if (!userId || !tg.TELEGRAM_BOT_TOKEN) return 0;
  const [link] = await sql<{ telegram_chat_id: string }[]>`
    select telegram_chat_id from telegram_links where user_id = ${userId} limit 1
  `;
  if (!link) return 0;
  try {
    await tg.sendMessage(link.telegram_chat_id, message, tg.withMenuButton(replyMarkup));
    return 1;
  } catch (e) {
    console.warn(`[telegram] ошибка отправки: ${e}`);
    return 0;
  }
}

/// Без ключа VAPID отправлять нечем — и это должно быть отказом, а не тихой
/// работой вхолостую.
///
/// Проверка не формальность: обход задач ОТМЕЧАЕТ отправленные будильники в
/// sent_push_notifications, и без ключа он проставил бы отметки, ничего не
/// отправив. Повторно такой будильник уже не сработает никогда — человек просто
/// не получит напоминание и не узнает, почему. Ровно это и произошло при первой
/// же проверке переезда 08.09.2026: за один вызов без настроенных секретов
/// сгорело десять будильников, отметки пришлось удалять руками.
function requireVapid(): void {
  if (!env("VAPID_PRIVATE_KEY")) throw new HttpError(500, "VAPID_PRIVATE_KEY не настроен");
}

export async function checkDueTasks(req: Request): Promise<Response> {
  requireInternalToken(req);
  requireVapid();

  const now = Date.now();
  let sentCount = 0;

  const tasks = await sql<TaskRow[]>`
    select id, user_id, title, due_date, due_time from tasks
    where is_completed is not true and due_date is not null and ${notDeleted()}
  `;

  for (const task of tasks) {
    const alarmAt = parseTaskDateTime(task.due_date, task.due_time);
    if (alarmAt === null) continue;

    for (const { offset, deltaMs, title } of ALARM_OFFSETS) {
      const targetTime = alarmAt.getTime() - deltaMs;
      if (targetTime < now - CHECK_WINDOW_MS || targetTime > now) continue;

      const [alreadySent] = await sql<{ task_id: number }[]>`
        select task_id from sent_push_notifications
        where task_id = ${task.id} and alarm_offset = ${offset}
        limit 1
      `;
      if (alreadySent) continue;

      const body = `Задача «${task.title}»`;
      sentCount += await sendWebPushToUser(task.user_id, title, body);
      sentCount += await sendTelegramToUser(
        task.user_id,
        `${title}\n«${task.title}»`,
        tg.doneButtonMarkup(task.id),
      );

      await sql`insert into sent_push_notifications ${
        sql({ task_id: task.id, alarm_offset: offset })
      }`;
    }
  }

  return json(req, { ok: true, sent: sentCount });
}

/// Задачи, которые лежат без движения дольше TASK_ROT_DAYS.
function rottingTasks(tasks: TaskRow[], now: number): TaskRow[] {
  const threshold = now - TASK_ROT_DAYS * DAY_MS;
  return tasks.filter((task) => {
    if (!task.created_at) return false;
    if (new Date(task.created_at).getTime() > threshold) return false;
    const deadline = parseTaskDateTime(task.due_date, task.due_time);
    // Без даты или уже просрочена — ровно как на карточке.
    if (task.due_date && deadline !== null && deadline.getTime() >= now) return false;
    return true;
  });
}

function utcDateString(date: Date): string {
  return new Intl.DateTimeFormat("ru-RU", {
    timeZone: "UTC",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(date);
}

export async function sendMorningDigest(req: Request): Promise<Response> {
  requireInternalToken(req);

  const now = new Date();
  const target = new Date(now);
  target.setUTCHours(MORNING_DIGEST_HOUR_UTC, 0, 0, 0);
  if (now.getTime() < target.getTime() || now.getTime() > target.getTime() + DIGEST_MAX_DELAY_MS) {
    return json(req, { ok: true, sent: 0 });
  }

  const todayStr = utcDateString(now);
  let sentCount = 0;

  const links = await sql<{ telegram_chat_id: string; user_id: string }[]>`
    select telegram_chat_id, user_id from telegram_links
  `;

  for (const link of links) {
    const [alreadySent] = await sql<{ user_id: string }[]>`
      select user_id from telegram_digest_sent
      where user_id = ${link.user_id} and digest_date = ${todayStr}
      limit 1
    `;
    if (alreadySent) continue;

    const tasks = await sql<TaskRow[]>`
      select id, title, due_date, due_time, created_at from tasks
      where user_id = ${link.user_id}
        and parent_id is null
        and is_completed is not true
        and ${notDeleted()}
    `;

    const todayPending = tasks.filter((t) => t.due_date === todayStr).length;
    const overdue = tasks.filter((t) => {
      const deadline = parseTaskDateTime(t.due_date, t.due_time);
      return deadline !== null && deadline.getTime() < now.getTime();
    }).length;

    const lines = ["Доброе утро! ☀️"];
    lines.push(
      todayPending ? `Сегодня задач: ${todayPending}.` : "На сегодня ничего не запланировано.",
    );
    if (overdue) lines.push(`Просрочено: ${overdue}.`);

    // Бейдж «лежит без движения N дней» на карточке нужно сначала заметить,
    // листая список; в утренней сводке тот же сигнал приходит сам. Сознательно
    // НЕ отдельным уведомлением: второй канал быстро превращается в шум, а
    // сводку человек и так читает раз в день.
    const rotting = rottingTasks(tasks, now.getTime());
    if (rotting.length > 0) {
      const titles = rotting.slice(0, ROT_DIGEST_LIMIT).map((t) => `«${t.title}»`).join(", ");
      const tail = rotting.length > ROT_DIGEST_LIMIT
        ? ` и ещё ${rotting.length - ROT_DIGEST_LIMIT}`
        : "";
      lines.push(`Лежат без движения дольше ${TASK_ROT_DAYS} дней: ${titles}${tail}.`);
    }

    try {
      await tg.sendMessage(link.telegram_chat_id, lines.join("\n"), tg.withMenuButton());
    } catch (e) {
      console.warn(`[telegram] ошибка отправки утренней сводки: ${e}`);
      continue;
    }

    await sql`insert into telegram_digest_sent ${
      sql({ user_id: link.user_id, digest_date: todayStr })
    }`;
    sentCount++;
  }

  return json(req, { ok: true, sent: sentCount });
}

export async function purgeTrash(req: Request): Promise<Response> {
  requireInternalToken(req);

  const cutoff = new Date(Date.now() - TRASH_RETENTION_DAYS * DAY_MS);

  // Пути файлов собираем ДО удаления: строки attachments уедут по каскаду
  // вместе с задачами, и после этого узнать, какие файлы освободились, будет
  // уже неоткуда — останется занятое навсегда место в хранилище.
  const doomedFiles = await sql<{ storage_path: string; thumb_path: string | null }[]>`
    select a.storage_path, a.thumb_path
    from attachments a
    join tasks t on t.id = a.task_id
    where t.deleted_at is not null and t.deleted_at < ${cutoff}
  `;

  // Подзадачи уедут сами по каскаду внешнего ключа, отдельно их искать не нужно.
  const purged = await sql<{ id: number }[]>`
    delete from tasks
    where deleted_at is not null and deleted_at < ${cutoff}
    returning id
  `;

  const filesRemoved = await removeUnreferencedFiles(doomedFiles);
  return json(req, { ok: true, purged: purged.length, files_removed: filesRemoved });
}

/// Сносит из хранилища файлы, на которые больше никто не ссылается.
///
/// Проверка обязательна: путь строится из хэша содержимого, поэтому один файл
/// может быть приложен к нескольким задачам и сообщениям. Удалить его вслед за
/// одной удалённой задачей значило бы оставить остальные с битой картинкой.
///
/// Именно удаление через Storage API, а не "delete from storage.objects": строка
/// в таблице — только учётная запись файла, сам файл живёт в объектном
/// хранилище, и прямое удаление строки оставило бы его там навсегда.
async function removeUnreferencedFiles(
  files: { storage_path: string; thumb_path: string | null }[],
): Promise<number> {
  if (files.length === 0) return 0;

  const paths = [
    ...new Set(files.flatMap((f) => [f.storage_path, ...(f.thumb_path ? [f.thumb_path] : [])])),
  ];
  const stillUsed = await sql<{ path: string }[]>`
    select storage_path as path from attachments where storage_path = any(${paths})
    union
    select thumb_path as path from attachments where thumb_path = any(${paths})
  `;
  const used = new Set(stillUsed.map((r) => r.path));
  const orphans = paths.filter((p) => !used.has(p));
  if (orphans.length === 0) return 0;

  const resp = await fetch(`${SUPABASE_URL}/storage/v1/object/attachments`, {
    method: "DELETE",
    headers: supabaseAdminHeaders(),
    body: JSON.stringify({ prefixes: orphans }),
  });
  if (!resp.ok) {
    // Место осталось занятым, но задачи удалены — это не повод валить уборку
    // целиком: следующий запуск подберёт только новые файлы, поэтому след в
    // журнале здесь единственное, что не даст проблеме стать незаметной.
    console.warn(
      `[trash] не удалось удалить ${orphans.length} файлов вложений: ${resp.status} ${await resp.text()}`,
    );
    return 0;
  }
  return orphans.length;
}

/// В отличие от напоминаний о дедлайнах (расписание раз в несколько минут —
/// приемлемая задержка), сообщения и назначения должны прилетать мгновенно,
/// поэтому дёргается не по расписанию, а Database Webhook сразу при изменении
/// таблицы. Один маршрут на все три типа — различаются по полю "table" в теле
/// запроса (стандартный формат пейлоада Database Webhooks).
export async function notifyEvent(req: Request): Promise<Response> {
  requireInternalToken(req);
  requireVapid();

  const payload = await req.json().catch(() => ({}));
  const table = payload?.table;
  const record = payload?.record ?? {};
  const oldRecord = payload?.old_record ?? {};

  let sentCount = 0;

  if (table === "messages") {
    // Личное сообщение — уведомляем получателя (to_id), не отправителя.
    const senderName = await getProfileName(record.from_id);
    const preview = String(record.text ?? "").slice(0, 120);
    sentCount += await sendWebPushToUser(record.to_id, "Новое сообщение", `${senderName}: ${preview}`);
  } else if (table === "workspace_messages") {
    // Командный чат — уведомляем всех участников команды, кроме отправителя.
    const senderId = record.from_id;
    const senderName = await getProfileName(senderId);
    const preview = String(record.text ?? "").slice(0, 120);
    const members = await sql<{ user_id: string }[]>`
      select user_id from workspace_members
      where workspace_id = ${record.workspace_id} and user_id <> ${senderId}
    `;
    for (const member of members) {
      sentCount += await sendWebPushToUser(
        member.user_id,
        "Новое сообщение в команде",
        `${senderName}: ${preview}`,
      );
    }
  } else if (table === "tasks") {
    // Назначение задачи — только если assigned_to реально сменился на нового
    // человека, а не любое обновление задачи (иначе спам на каждый чек-бокс).
    const newAssignee = record.assigned_to;
    const oldAssignee = oldRecord.assigned_to;
    if (newAssignee && newAssignee !== oldAssignee) {
      const title = record.title ?? "Задача";
      sentCount += await sendWebPushToUser(newAssignee, "Вам назначили задачу", `«${title}»`);
    }
  }

  return json(req, { ok: true, sent: sentCount });
}
