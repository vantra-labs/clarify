/// Clarify как MCP-сервер: сторонняя нейросеть работает с задачами человека.
///
/// Человек подключает Claude, Cursor или другой клиент к своему Clarify одним
/// адресом и ключом — и дальше говорит уже им: «что у меня на завтра»,
/// «создай задачу», «закрой всё по объекту на Ленина».
///
/// Транспорт — Streamable HTTP, но БЕЗ состояния: одна edge-функция может
/// подниматься во множестве экземпляров разом, и сессия, заведённая в одном,
/// в следующем запросе не найдётся. Поэтому ключ приходит с каждым запросом, а
/// сессии нет вовсе. Спецификация это разрешает: сервер без потоковой отдачи
/// отвечает обычным JSON и не выдаёт Mcp-Session-Id.
///
/// Версий протокола в ходу несколько, и клиенты обновляются вразнобой, поэтому
/// поддерживаются и старое рукопожатие initialize, и новое server/discover.
import { notDeleted, sql } from "../../_shared/db.ts";
import { corsHeaders } from "../../_shared/http.ts";

/// Версия, на которой мы говорим, если клиент не назвал свою.
const DEFAULT_PROTOCOL = "2025-06-18";

/// Версии, которые мы понимаем. Если клиент просит одну из них — отвечаем
/// ровно ей: различия для сервера, у которого только инструменты, косметические.
const SUPPORTED_PROTOCOLS = [
  "2026-07-28",
  "2025-11-25",
  "2025-06-18",
  "2025-03-26",
];

const SERVER_INFO = {
  name: "clarify",
  title: "Clarify",
  version: "1.0.0",
};

const INSTRUCTIONS = [
  "Задачи планировщика Clarify.",
  "Даты — строкой ДД.ММ.ГГГГ, время — ЧЧ:ММ (24 часа).",
  "Приоритеты: red (срочно), orange (важно), blue (обычный), none (потом).",
  "Теги перечисляются через запятую в одном поле tags.",
  "Прежде чем менять или закрывать задачу, найди её через list_tasks или",
  "search_tasks и возьми оттуда id — придумывать id нельзя.",
].join(" ");

// --------------------------------------------------------------------------
// JSON-RPC
// --------------------------------------------------------------------------

interface RpcRequest {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
}

const RPC_PARSE_ERROR = -32700;
const RPC_INVALID_REQUEST = -32600;
const RPC_METHOD_NOT_FOUND = -32601;
const RPC_INVALID_PARAMS = -32602;

function rpcResult(req: Request, id: unknown, result: unknown): Response {
  return new Response(JSON.stringify({ jsonrpc: "2.0", id, result }), {
    status: 200,
    headers: { ...corsHeaders(req), "Content-Type": "application/json" },
  });
}

function rpcError(
  req: Request,
  id: unknown,
  code: number,
  message: string,
  status = 200,
  data?: unknown,
): Response {
  return new Response(
    JSON.stringify({ jsonrpc: "2.0", id: id ?? null, error: { code, message, data } }),
    {
      status,
      headers: { ...corsHeaders(req), "Content-Type": "application/json" },
    },
  );
}

/// Ответ инструмента. isError — это НЕ ошибка протокола: нейросети нужно
/// прочитать, что именно не вышло, и попробовать иначе, поэтому текст ошибки
/// возвращается ей как обычный ответ, а не как отказ JSON-RPC.
function toolText(text: string, isError = false) {
  return { content: [{ type: "text", text }], isError };
}

// --------------------------------------------------------------------------
// Ключ подключения
// --------------------------------------------------------------------------

/// Отпечаток ключа. В базе лежит только он — сам ключ не хранится нигде.
async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/// Достаёт ключ из запроса.
///
/// Заголовок Authorization — основной способ. Ключ в конце адреса
/// (.../mcp/clarify_xxx) — запасной: часть клиентов умеет только вставить
/// ссылку и не даёт задать заголовки.
function extractToken(req: Request): string | null {
  const header = req.headers.get("authorization") ?? "";
  const bearer = header.match(/^Bearer\s+(.+)$/i);
  if (bearer) return bearer[1].trim();

  const path = new URL(req.url).pathname;
  const inPath = path.match(/\/mcp\/([^/]+)$/);
  if (inPath) return decodeURIComponent(inPath[1]);

  return null;
}

/// Владелец ключа или null.
///
/// Отметка последнего использования — не аудит ради аудита: без неё человек,
/// глядя на список ключей, не может понять, какой из них ещё живой, и боится
/// удалять любой.
async function resolveUser(token: string): Promise<string | null> {
  const hash = await hashToken(token);
  const rows = await sql<{ user_id: string }[]>`
    update mcp_tokens set last_used_at = now()
    where token_hash = ${hash}
    returning user_id
  `;
  return rows.length > 0 ? rows[0].user_id : null;
}

// --------------------------------------------------------------------------
// Инструменты
// --------------------------------------------------------------------------

const TOOLS = [
  {
    name: "list_tasks",
    title: "Список задач",
    description:
      "Задачи человека. Без аргументов — все невыполненные. Возвращает id, " +
      "которые нужны для complete_task и update_task.",
    inputSchema: {
      type: "object",
      properties: {
        scope: {
          type: "string",
          enum: ["today", "overdue", "week", "inbox", "all"],
          description:
            "today — на сегодня, overdue — просроченные, week — ближайшие 7 дней, " +
            "inbox — без даты, all — все. По умолчанию all.",
        },
        include_completed: {
          type: "boolean",
          description: "Включать выполненные. По умолчанию нет.",
        },
        tag: { type: "string", description: "Только задачи с этим тегом." },
        limit: { type: "integer", description: "Сколько вернуть, по умолчанию 50." },
      },
    },
  },
  {
    name: "search_tasks",
    title: "Поиск задач",
    description: "Ищет задачи по куску текста в названии или заметке.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Что искать." },
        limit: { type: "integer", description: "Сколько вернуть, по умолчанию 20." },
      },
      required: ["query"],
    },
  },
  {
    name: "create_task",
    title: "Создать задачу",
    description: "Создаёт задачу. Дата ДД.ММ.ГГГГ, время ЧЧ:ММ.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Название задачи." },
        due_date: { type: "string", description: "Дата ДД.ММ.ГГГГ. Без неё задача во «Входящих»." },
        due_time: { type: "string", description: "Время ЧЧ:ММ." },
        priority: {
          type: "string",
          enum: ["red", "orange", "blue", "none"],
          description: "red — срочно, orange — важно, blue — обычный, none — потом.",
        },
        tags: { type: "string", description: "Теги через запятую." },
        note: { type: "string", description: "Заметка." },
      },
      required: ["title"],
    },
  },
  {
    name: "update_task",
    title: "Изменить задачу",
    description:
      "Меняет поля задачи. Передавать только те поля, которые нужно изменить. " +
      "id брать из list_tasks или search_tasks.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "integer", description: "Номер задачи." },
        title: { type: "string" },
        due_date: { type: "string", description: "Дата ДД.ММ.ГГГГ. Пустая строка — убрать дату." },
        due_time: { type: "string", description: "Время ЧЧ:ММ. Пустая строка — убрать время." },
        priority: { type: "string", enum: ["red", "orange", "blue", "none"] },
        tags: { type: "string" },
        note: { type: "string" },
      },
      required: ["id"],
    },
  },
  {
    name: "complete_task",
    title: "Отметить выполненной",
    description: "Отмечает задачу выполненной или снимает отметку.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "integer", description: "Номер задачи." },
        completed: { type: "boolean", description: "По умолчанию true." },
      },
      required: ["id"],
    },
  },
  {
    name: "delete_task",
    title: "Удалить задачу",
    description:
      "Переносит задачу в корзину приложения. Оттуда её можно вернуть, " +
      "окончательно она удалится сама через 30 дней.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "integer", description: "Номер задачи." } },
      required: ["id"],
    },
  },
];

/// Дата в том виде, в каком её хранит приложение: ДД.ММ.ГГГГ.
function formatDate(date: Date): string {
  const day = String(date.getDate()).padStart(2, "0");
  const month = String(date.getMonth() + 1).padStart(2, "0");
  return `${day}.${month}.${date.getFullYear()}`;
}

/// Проверка формата даты. Строгая: молча принять «2026-09-10» значило бы
/// создать задачу, которая не покажется человеку ни в одном разделе.
function isValidDate(value: string): boolean {
  return /^\d{2}\.\d{2}\.\d{4}$/.test(value);
}

function isValidTime(value: string): boolean {
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(value);
}

interface TaskBrief {
  id: number;
  title: string | null;
  due_date: string | null;
  due_time: string | null;
  priority: string | null;
  tags: string | null;
  note: string | null;
  is_completed: boolean | null;
}

/// Задачи для нейросети — текстом, а не JSON.
///
/// Модель одинаково хорошо читает и то, и другое, а человек, который смотрит на
/// переписку с ассистентом, читает только текст. JSON в ответе выглядел бы как
/// сбой.
function renderTasks(tasks: TaskBrief[]): string {
  if (tasks.length === 0) return "Задач нет.";
  return tasks
    .map((task) => {
      const parts = [`#${task.id}`, task.title ?? "(без названия)"];
      if (task.due_date) {
        parts.push(task.due_time ? `${task.due_date} ${task.due_time}` : task.due_date);
      } else {
        parts.push("без даты");
      }
      if (task.priority && task.priority !== "none") parts.push(`приоритет ${task.priority}`);
      if (task.tags) parts.push(`теги: ${task.tags}`);
      if (task.is_completed) parts.push("выполнена");
      if (task.note) parts.push(`заметка: ${task.note}`);
      return parts.join(" — ");
    })
    .join("\n");
}

/// Колонки списком, а не строкой: postgres.js сам соберёт из массива
/// безопасный перечень имён (sql.unsafe тут был бы дырой на ровном месте).
const TASK_COLUMNS = [
  "id",
  "title",
  "due_date",
  "due_time",
  "priority",
  "tags",
  "note",
  "is_completed",
];

async function runTool(
  userId: string,
  name: string,
  args: Record<string, unknown>,
): Promise<{ content: unknown[]; isError: boolean }> {
  switch (name) {
    case "list_tasks": {
      const scope = (args.scope as string) ?? "all";
      const includeCompleted = args.include_completed === true;
      const limit = Math.min(Math.max(Number(args.limit) || 50, 1), 200);
      const tag = (args.tag as string | undefined)?.trim();

      // Даты в базе лежат строкой ДД.ММ.ГГГГ, сравнивать их как строки нельзя
      // («31.08.2026» больше «05.09.2026»), поэтому нужные дни считаем здесь и
      // сравниваем на равенство.
      const today = new Date();
      const days: string[] = [];
      const horizon = scope === "week" ? 7 : 1;
      for (let i = 0; i < horizon; i++) {
        const d = new Date(today);
        d.setDate(today.getDate() + i);
        days.push(formatDate(d));
      }

      const rows = await sql<TaskBrief[]>`
        select ${sql(TASK_COLUMNS)} from tasks
        where user_id = ${userId}
          and parent_id is null
          and ${notDeleted()}
          ${includeCompleted ? sql`` : sql`and coalesce(is_completed, false) = false`}
          ${
        scope === "inbox"
          ? sql`and (due_date is null or due_date = '')`
          : scope === "today" || scope === "week"
          ? sql`and due_date = any(${days})`
          : sql``
      }
          ${tag ? sql`and tags ilike ${"%" + tag + "%"}` : sql``}
        order by id desc
        limit ${limit}
      `;

      // «Просроченные» отбираются здесь, а не в SQL: сравнение дат-строк в базе
      // дало бы неверный порядок, а переписывать хранение ради одного фильтра —
      // менять формат данных во всём приложении.
      const result = scope === "overdue"
        ? rows.filter((task) => {
          if (!task.due_date || !isValidDate(task.due_date)) return false;
          const [d, m, y] = task.due_date.split(".").map(Number);
          const due = new Date(y, m - 1, d);
          const midnight = new Date(today.getFullYear(), today.getMonth(), today.getDate());
          return due < midnight;
        })
        : rows;

      return toolText(renderTasks(result));
    }

    case "search_tasks": {
      const query = (args.query as string | undefined)?.trim();
      if (!query) return toolText("Нужно указать, что искать.", true);
      const limit = Math.min(Math.max(Number(args.limit) || 20, 1), 200);
      const pattern = `%${query}%`;
      const rows = await sql<TaskBrief[]>`
        select ${sql(TASK_COLUMNS)} from tasks
        where user_id = ${userId}
          and ${notDeleted()}
          and (title ilike ${pattern} or note ilike ${pattern})
        order by id desc
        limit ${limit}
      `;
      return toolText(renderTasks(rows));
    }

    case "create_task": {
      const title = (args.title as string | undefined)?.trim();
      if (!title) return toolText("У задачи должно быть название.", true);

      const dueDate = (args.due_date as string | undefined)?.trim() || null;
      if (dueDate && !isValidDate(dueDate)) {
        return toolText(`Дата должна быть в виде ДД.ММ.ГГГГ, пришло: ${dueDate}`, true);
      }
      const dueTime = (args.due_time as string | undefined)?.trim() || null;
      if (dueTime && !isValidTime(dueTime)) {
        return toolText(`Время должно быть в виде ЧЧ:ММ, пришло: ${dueTime}`, true);
      }

      const [created] = await sql<TaskBrief[]>`
        insert into tasks ${
        sql({
          user_id: userId,
          title,
          due_date: dueDate,
          due_time: dueTime,
          priority: (args.priority as string | undefined) ?? "none",
          tags: (args.tags as string | undefined)?.trim() || null,
          note: (args.note as string | undefined)?.trim() || null,
          is_completed: false,
          parent_id: null,
        })
      } returning ${sql(TASK_COLUMNS)}
      `;
      return toolText(`Создана задача:\n${renderTasks([created])}`);
    }

    case "update_task": {
      const id = Number(args.id);
      if (!Number.isInteger(id)) return toolText("Нужен номер задачи (id).", true);

      const updates: Record<string, unknown> = {};
      for (const field of ["title", "due_date", "due_time", "priority", "tags", "note"]) {
        if (!(field in args)) continue;
        const raw = args[field];
        const value = typeof raw === "string" ? raw.trim() : raw;
        // Пустая строка — это «убрать значение», а не «поставить пустое»:
        // пустая дата в базе сломала бы разбор дедлайна.
        updates[field] = value === "" ? null : value;
      }
      if (updates.due_date && !isValidDate(String(updates.due_date))) {
        return toolText(`Дата должна быть в виде ДД.ММ.ГГГГ, пришло: ${updates.due_date}`, true);
      }
      if (updates.due_time && !isValidTime(String(updates.due_time))) {
        return toolText(`Время должно быть в виде ЧЧ:ММ, пришло: ${updates.due_time}`, true);
      }
      if (Object.keys(updates).length === 0) {
        return toolText("Не указано ни одного поля для изменения.", true);
      }

      // Фильтр по user_id обязателен в КАЖДОМ запросе: функция ходит в базу
      // служебным подключением, правила доступа на таблице к ней не
      // применяются, и без этого условия номер чужой задачи открыл бы её.
      const rows = await sql<TaskBrief[]>`
        update tasks set ${sql(updates)}
        where id = ${id} and user_id = ${userId} and ${notDeleted()}
        returning ${sql(TASK_COLUMNS)}
      `;
      if (rows.length === 0) return toolText(`Задача #${id} не найдена.`, true);
      return toolText(`Изменено:\n${renderTasks(rows)}`);
    }

    case "complete_task": {
      const id = Number(args.id);
      if (!Number.isInteger(id)) return toolText("Нужен номер задачи (id).", true);
      const completed = args.completed === undefined ? true : args.completed === true;

      const rows = await sql<TaskBrief[]>`
        update tasks
        set is_completed = ${completed},
            completed_at = ${completed ? new Date() : null}
        where id = ${id} and user_id = ${userId} and ${notDeleted()}
        returning ${sql(TASK_COLUMNS)}
      `;
      if (rows.length === 0) return toolText(`Задача #${id} не найдена.`, true);
      return toolText(
        completed ? `Отмечена выполненной:\n${renderTasks(rows)}` : `Отметка снята:\n${renderTasks(rows)}`,
      );
    }

    case "delete_task": {
      const id = Number(args.id);
      if (!Number.isInteger(id)) return toolText("Нужен номер задачи (id).", true);
      // В корзину, а не насовсем: удаление по слову нейросети должно быть
      // обратимым. Через 30 дней корзина вычистит задачу сама.
      const rows = await sql<{ id: number }[]>`
        update tasks set deleted_at = now()
        where id = ${id} and user_id = ${userId} and ${notDeleted()}
        returning id
      `;
      if (rows.length === 0) return toolText(`Задача #${id} не найдена.`, true);
      return toolText(`Задача #${id} перенесена в корзину.`);
    }

    default:
      return toolText(`Неизвестный инструмент: ${name}`, true);
  }
}

// --------------------------------------------------------------------------
// Маршрут
// --------------------------------------------------------------------------

export async function mcpRoute(req: Request): Promise<Response> {
  // Потоковой отдачи (SSE) у нас нет: инструменты отвечают сразу и целиком.
  // Спецификация разрешает в таком случае отказать на GET.
  if (req.method === "GET") {
    return new Response(
      JSON.stringify({ detail: "Поток не поддерживается, используйте POST" }),
      {
        status: 405,
        headers: { ...corsHeaders(req), "Content-Type": "application/json", Allow: "POST" },
      },
    );
  }

  const token = extractToken(req);
  if (!token) {
    return new Response(
      JSON.stringify({ detail: "Нужен ключ подключения" }),
      {
        status: 401,
        headers: {
          ...corsHeaders(req),
          "Content-Type": "application/json",
          "WWW-Authenticate": "Bearer",
        },
      },
    );
  }

  const userId = await resolveUser(token);
  if (!userId) {
    return new Response(
      JSON.stringify({ detail: "Ключ не действует" }),
      {
        status: 401,
        headers: {
          ...corsHeaders(req),
          "Content-Type": "application/json",
          "WWW-Authenticate": "Bearer",
        },
      },
    );
  }

  let body: RpcRequest | RpcRequest[];
  try {
    body = await req.json();
  } catch {
    return rpcError(req, null, RPC_PARSE_ERROR, "Тело запроса не разобрать");
  }

  // Пакет запросов клиенты шлют редко, но спецификация это допускает. Берём
  // первый содержательный: сессии у нас нет, порядок ничего не значит.
  const message = Array.isArray(body) ? body.find((m) => m?.method) ?? body[0] : body;
  if (!message || typeof message.method !== "string") {
    return rpcError(req, null, RPC_INVALID_REQUEST, "Нет метода");
  }

  const id = message.id ?? null;
  const params = message.params ?? {};

  // Уведомления (id нет) ответа не требуют — отвечаем пустым принятием.
  const isNotification = message.id === undefined || message.id === null;

  switch (message.method) {
    case "initialize": {
      const asked = params.protocolVersion as string | undefined;
      const version = asked && SUPPORTED_PROTOCOLS.includes(asked) ? asked : DEFAULT_PROTOCOL;
      return rpcResult(req, id, {
        protocolVersion: version,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    }

    // Рукопожатие версии 2026-07-28: вместо initialize клиент спрашивает, что
    // сервер умеет, и дальше шлёт всё нужное в каждом запросе.
    case "server/discover": {
      return rpcResult(req, id, {
        resultType: "complete",
        supportedVersions: SUPPORTED_PROTOCOLS,
        capabilities: { tools: {} },
        instructions: INSTRUCTIONS,
        _meta: { "io.modelcontextprotocol/serverInfo": SERVER_INFO },
      });
    }

    case "notifications/initialized":
    case "notifications/cancelled":
      return new Response(null, { status: 202, headers: corsHeaders(req) });

    case "ping":
      return rpcResult(req, id, {});

    case "tools/list":
      return rpcResult(req, id, { tools: TOOLS });

    case "tools/call": {
      const name = params.name as string | undefined;
      if (!name) return rpcError(req, id, RPC_INVALID_PARAMS, "Не указан инструмент");
      const args = (params.arguments as Record<string, unknown>) ?? {};
      try {
        return rpcResult(req, id, await runTool(userId, name, args));
      } catch (e) {
        console.error(`[mcp] ${name} упал: ${e}`);
        // Отказ инструмента отдаём как ответ инструмента, а не как ошибку
        // протокола: клиент покажет её модели, и та сможет исправиться.
        return rpcResult(req, id, toolText(`Не получилось выполнить: ${e}`, true));
      }
    }

    // Ресурсов и подсказок у нас нет, но клиенты спрашивают о них при
    // подключении. Пустой список честнее ошибки: с ошибкой некоторые клиенты
    // считают сервер сломанным целиком.
    case "resources/list":
      return rpcResult(req, id, { resources: [] });
    case "resources/templates/list":
      return rpcResult(req, id, { resourceTemplates: [] });
    case "prompts/list":
      return rpcResult(req, id, { prompts: [] });

    default: {
      if (isNotification) {
        return new Response(null, { status: 202, headers: corsHeaders(req) });
      }
      return rpcError(req, id, RPC_METHOD_NOT_FOUND, `Метод не поддерживается: ${message.method}`);
    }
  }
}
