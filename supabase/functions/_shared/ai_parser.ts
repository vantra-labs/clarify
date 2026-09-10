/// ИИ-ассистент: разбор свободного текста пользователя в ответ + действия.
///
/// Общий для /tasks/parse (чат в самом приложении) и Telegram-бота — один
/// промпт и одна цепочка моделей на оба канала, а не две расходящиеся копии.
import { env } from "./env.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";

/// Таймаут на КАЖДУЮ попытку.
///
/// Было 15 секунд — унаследовано от прежнего бэкенда. Замеры 08.09.2026
/// показали, что это слишком мало: nemotron-lightning на том же промпте
/// отвечал то за пять секунд, то за пятьдесят две. В пятнадцать секунд рабочая
/// модель просто не укладывалась, попытка отбрасывалась, и при двух мёртвых
/// моделях в списке цепочка вырождалась в отказ «не получилось связаться с
/// ИИ» — при том что модель в этот момент считала ответ и в итоге его выдала.
///
/// Повторов внутри попытки нет намеренно: свой fallback на следующую модель
/// уже есть, и дублировать его ретраями значит только удлинять путь до модели,
/// которая реально ответит.
const ATTEMPT_TIMEOUT_MS = 25_000;

/// Список бесплатных моделей: если одна упала или перегружена, пробуем следующую.
///
/// Список ПРОТУХАЕТ. Бесплатные модели на OpenRouter снимают и переводят в
/// платные без предупреждения, и тогда цепочка молча вырождается в ноль
/// рабочих, а пользователь видит только «Не получилось связаться с ИИ». Ровно
/// это и случилось к 04.09.2026: из четырёх ID, выверенных 01.08.2026, три
/// перестали существовать, а четвёртый упёрся в лимит провайдера — ассистент в
/// боте не работал вообще.
///
/// Поэтому модели разных провайдеров: лимит одного не убивает цепочку целиком.
/// Порядок — от быстрой к тяжёлой.
///
/// Проверено живыми запросами 08.09.2026, при переезде бэкенда. Обе модели
/// minimax из прежнего списка к этому дню уехали в платные и отвечали 404 —
/// то есть из четырёх запасных вариантов рабочими оставались два, и первый же
/// сбой одного из них клал ассистента целиком. Ровно это и увидел владелец:
/// на первое сообщение боту пришло «Не получилось связаться с ИИ», на второе,
/// через пять минут, — нормальная карточка задачи.
///
/// Из проверенных на замену: nex-n2.5-mini отвечает валидным JSON примерно за
/// десять секунд; inkling-small, nex-n2.5-pro и north-mini-code не уложились в
/// сорок секунд и в цепочку не годятся; gemma часто отдаёт 429 из общего
/// бесплатного пула, но отказ приходит мгновенно и место в конце занимает
/// небесполезно.
/// Порядок — по замеренному времени ответа, а не по «весу» модели. Вопреки
/// названиям, тяжёлая nemotron-super отвечала стабильнее и быстрее (шесть
/// секунд), чем lightning, которая на том же промпте гуляла от пяти секунд до
/// пятидесяти двух. Первой стоит та, что реально отвечает быстрее.
export const MODELS_TO_TRY = [
  "nvidia/nemotron-3-super-120b-a12b:free",
  "nvidia/nemotron-3.5-lightning:free",
  "nex-agi/nex-n2.5-mini:free",
  "google/gemma-4-31b-it:free",
];

/// Поля задачи, которые ИИ разрешено выставлять при создании/правке — единый
/// список, чтобы не дублировать перечисление в системном промпте и в местах,
/// где эти поля читаются из ответа модели.
export const TASK_FIELDS = ["title", "due_date", "due_time", "note", "priority", "tags"] as const;

export interface AssistantAction {
  type: "create" | "update";
  task_id?: number;
  is_completed?: boolean;
  [field: string]: unknown;
}

export interface AssistantResult {
  reply: string;
  actions: AssistantAction[];
}

export interface HistoryTurn {
  role?: string;
  text?: string;
}

/// Задача в том виде, в каком её видит ассистент (и Telegram-бот в /today).
export interface AssistantTask {
  id: number;
  title: string | null;
  due_date: string | null;
  due_time: string | null;
  priority: string | null;
  tags: string | null;
  note: string | null;
  checklist: unknown;
}

function formatExistingTasks(tasks: AssistantTask[]): string {
  if (tasks.length === 0) return "(текущих незавершённых задач нет)";
  // Компактный JSON, не полные объекты задачи — только то, что нужно модели,
  // чтобы сослаться на задачу (id) и понять, о какой из них речь.
  const compact = tasks.map((t) => ({
    id: t.id,
    title: t.title,
    due_date: t.due_date,
    due_time: t.due_time,
    priority: t.priority,
    tags: t.tags,
  }));
  return JSON.stringify(compact);
}

function buildSystemPrompt(currentDate: string, tasks: AssistantTask[]): string {
  return `
Сегодняшняя дата: ${currentDate}.
Ты — ИИ-ассистент внутри планировщика задач Clarify. Пользователь пишет тебе
свободным текстом (или голосом, распознанным в текст) — задачу для создания,
просьбу изменить/перенести/отметить выполненной существующую задачу, или
вопрос про свои задачи.

Верни СТРОГО один JSON-объект, без markdown и пояснений вокруг:
{"reply": "...", "actions": [...]}

"reply" — короткий дружелюбный ответ пользователю на русском (или на языке
его сообщения), который увидит он сам в чате. Всегда заполнен, даже если
actions пустой.

"actions" — список действий, каждое одного из двух типов:
1. Создать новую задачу:
   {"type": "create", "title": "суть, макс 20 символов", "due_date": "ДД.ММ.ГГГГ" или null, "due_time": "ЧЧ:ММ" или null, "note": "подробности" или null, "priority": "red"/"orange"/"blue"/"gray"/"none", "tags": "одно слово-тег без решётки" или null}
2. Изменить существующую задачу (бери "id" СТРОГО из списка текущих задач ниже, не выдумывай):
   {"type": "update", "task_id": <id>, "is_completed": true/false — только если просят отметить выполненной/невыполненной, и/или любые поля из create выше, которые нужно поменять}

Даты пересчитывай от ${currentDate} для слов вроде "завтра"/"в пятницу"/"через неделю".

Если пользователь просто спрашивает о своих задачах ("что у меня сегодня?",
"сколько просрочено?") — ответь в "reply" по списку текущих задач ниже,
"actions" оставь пустым массивом.

Если похоже, что пользователь хочет УДАЛИТЬ задачу — сам не удаляй (типа
"delete" не существует), вместо этого в "reply" уточни, какую именно задачу
он имеет в виду, и попроси подтвердить явно словами в следующем сообщении.

Текущие незавершённые задачи пользователя (используй их id для update,
отвечай на вопросы по ним): ${formatExistingTasks(tasks)}
`.trim();
}

/// Достаёт JSON-объект из ответа модели.
///
/// Модели любят обернуть ответ в markdown-заборчик или дописать фразу вокруг —
/// вырезаем первый же объект от "{" до последней "}", и только если не нашли,
/// пробуем разобрать весь текст целиком.
function extractJsonObject(rawText: string): Record<string, unknown> {
  const match = rawText.match(/\{[\s\S]*\}/);
  const parsed = JSON.parse(match ? match[0] : rawText);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("Ответ ИИ распарсился, но это не JSON-объект");
  }
  return parsed as Record<string, unknown>;
}

function normalizeResult(parsed: Record<string, unknown>): AssistantResult {
  let reply = parsed.reply;
  if (typeof reply !== "string" || !reply.trim()) reply = "Готово.";

  const rawActions = Array.isArray(parsed.actions) ? parsed.actions : [];
  const actions: AssistantAction[] = [];
  for (const action of rawActions) {
    if (typeof action !== "object" || action === null) continue;
    const typed = action as AssistantAction;
    if (typed.type !== "create" && typed.type !== "update") continue;
    // update без числового id некуда применить: попытка «починить» его
    // догадкой — это правка чужой или случайной задачи.
    if (typed.type === "update" && !Number.isInteger(typed.task_id)) continue;
    actions.push(typed);
  }
  return { reply: reply as string, actions };
}

async function callModel(
  model: string,
  messages: Array<{ role: string; content: string }>,
): Promise<string> {
  const apiKey = env("OPENROUTER_API_KEY");
  if (!apiKey) throw new Error("OPENROUTER_API_KEY не настроен");

  const resp = await fetch(OPENROUTER_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ model, messages }),
    signal: AbortSignal.timeout(ATTEMPT_TIMEOUT_MS),
  });
  if (!resp.ok) {
    throw new Error(`OpenRouter ответил ${resp.status}: ${(await resp.text()).slice(0, 200)}`);
  }
  const data = await resp.json();
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    throw new Error("OpenRouter вернул ответ без текста");
  }
  return content.trim();
}

/// Разбирает сообщение пользователя в {reply, actions}.
///
/// history — последние сообщения чата ([{role: "user"|"ai", text}]) для
/// контекста многоходовой переписки (например «нет, не на 16, а на 18» как
/// правка предыдущего сообщения).
export async function runAssistant(
  text: string,
  existingTasks: AssistantTask[],
  history: HistoryTurn[],
): Promise<AssistantResult> {
  // Дата по UTC — ровно то же, что делал datetime.now() на Render (там
  // контейнер тоже жил в UTC). Специально не переведено на Москву при
  // переезде: это изменило бы поведение ассистента, а переезд обязан
  // сохранять его один в один. Расхождение при этом реальное — с 03:00 МСК
  // серверная дата ещё вчерашняя относительно пользователя, и «завтра» на
  // ночной планёрке разъедется на день. Чинить это надо отдельно и вместе с
  // тем же вопросом в утренней сводке и в /today у бота, где часового пояса
  // пользователя у бэкенда тоже нет.
  const currentDate = new Intl.DateTimeFormat("ru-RU", {
    timeZone: "UTC",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(new Date());

  const messages = [{ role: "system", content: buildSystemPrompt(currentDate, existingTasks) }];
  for (const turn of history) {
    const role = turn.role === "ai" ? "assistant" : "user";
    if (turn.text) messages.push({ role, content: turn.text });
  }
  messages.push({ role: "user", content: text });

  let lastError: unknown = null;

  for (const model of MODELS_TO_TRY) {
    let rawText: string;
    try {
      rawText = await callModel(model, messages);
    } catch (e) {
      console.warn(`[ai] сбой на модели ${model}: ${String(e).slice(0, 200)}`);
      lastError = e;
      continue;
    }

    try {
      return normalizeResult(extractJsonObject(rawText));
    } catch (e) {
      // Модель ответила, но не валидным JSON — даём ей одну попытку починить
      // собственный ответ, вместо того чтобы списывать рабочую модель со
      // счетов только из-за кривого форматирования вывода.
      console.warn(`[ai] модель ${model} ответила не JSON-объектом: ${e}`);
      lastError = e;
      try {
        const corrected = await callModel(model, [
          ...messages,
          { role: "assistant", content: rawText },
          {
            role: "user",
            content:
              `Это не валидный JSON-объект (${e}). Верни ИСПРАВЛЕННЫЙ валидный JSON-объект в описанном формате, и ничего больше.`,
          },
        ]);
        return normalizeResult(extractJsonObject(corrected));
      } catch (e2) {
        console.warn(`[ai] самокоррекция тоже не удалась: ${String(e2).slice(0, 200)}`);
        lastError = e2;
        continue;
      }
    }
  }

  console.error(`[ai] ВСЕ МОДЕЛИ НЕДОСТУПНЫ. Последняя ошибка: ${lastError}`);
  return {
    reply: "Не получилось связаться с ИИ — попробуй ещё раз чуть позже.",
    actions: [],
  };
}
