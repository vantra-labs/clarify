/// Работа с задачами на стороне бэкенда.
///
/// Здесь только то, что бэкенд делает САМ: читает задачи для ассистента,
/// выполняет его действия, считает время дедлайна для будильников. Обычный
/// CRUD задач сюда не относится — его клиент делает напрямую через Supabase,
/// мимо этого кода.
import { notDeleted, sql } from "./db.ts";
import { type AssistantAction, type AssistantTask, TASK_FIELDS } from "./ai_parser.ts";

export interface TaskRow {
  id: number;
  user_id: string | null;
  title: string | null;
  due_date: string | null;
  due_time: string | null;
  note: string | null;
  is_completed: boolean | null;
  completed_at: Date | null;
  priority: string | null;
  tags: string | null;
  parent_id: number | null;
  recurrence: string | null;
  checklist: unknown;
  created_at: Date | null;
  deleted_at: Date | null;
  [column: string]: unknown;
}

/// Незавершённые собственные задачи пользователя (без подзадач — ими ИИ не
/// оперирует). Это контекст, по которому ассистент отвечает на вопросы и
/// находит id для update. Та же таблица — источник правды и для самого
/// приложения, так что задачи здесь настоящие, актуальные.
///
/// note/checklist в промпт ассистенту не идут (formatExistingTasks берёт
/// только часть полей, чтобы не раздувать промпт) — они нужны Telegram-боту
/// для полного /today и /все.
export async function fetchExistingTasksForAssistant(userId: string): Promise<AssistantTask[]> {
  const rows = await sql<AssistantTask[]>`
    select id, title, due_date, due_time, priority, tags, note, checklist
    from tasks
    where user_id = ${userId}
      and is_completed = false
      and parent_id is null
      and ${notDeleted()}
  `;
  return rows;
}

export type AffectedTask = { type: "create" | "update"; task: TaskRow };

/// Выполняет create/update-действия ассистента и возвращает, что реально
/// произошло с каждой задачей — тип нужен, например, боту в Telegram, чтобы
/// показать разную карточку подтверждения для «добавлено» и «изменено».
/// Общая для /tasks/parse и Telegram-бота — не дублировать этот цикл отдельно.
export async function executeAssistantActions(
  userId: string,
  actions: AssistantAction[],
  fallbackTitle: string,
): Promise<AffectedTask[]> {
  const affected: AffectedTask[] = [];

  for (const action of actions) {
    if (action.type === "create") {
      const row = {
        title: (action.title as string | null) || fallbackTitle,
        due_date: (action.due_date as string | null) ?? null,
        due_time: (action.due_time as string | null) ?? null,
        note: (action.note as string | null) ?? null,
        priority: (action.priority as string | null) ?? "none",
        tags: (action.tags as string | null) ?? null,
        user_id: userId,
        is_completed: false,
        recurrence: null,
        parent_id: null,
      };
      const [created] = await sql<TaskRow[]>`insert into tasks ${sql(row)} returning *`;
      affected.push({ type: "create", task: created });
      continue;
    }

    if (action.type !== "update") continue;

    // Ищем СТРОГО среди задач этого же user_id — id пришёл от модели, которая
    // теоретически могла бы что-то напутать, но затронуть чужую задачу через
    // это всё равно нельзя (IDOR-защита).
    const [existing] = await sql<TaskRow[]>`
      select * from tasks
      where id = ${action.task_id!} and user_id = ${userId} and ${notDeleted()}
      limit 1
    `;
    if (!existing) continue;

    const updates: Record<string, unknown> = {};
    for (const field of TASK_FIELDS) {
      if (field in action) updates[field] = action[field] ?? null;
    }
    if ("is_completed" in action) {
      const newStatus = Boolean(action.is_completed);
      updates.is_completed = newStatus;
      // Та же пара полей, что и _toggleTask на фронтенде: проставляется при
      // отметке выполненной, сбрасывается при снятии. Без этого статистика
      // (серия дней подряд, тепловая карта) тихо не видела бы задачи,
      // закрытые через ассистента.
      updates.completed_at = newStatus ? new Date() : null;
    }

    if (Object.keys(updates).length === 0) {
      // Модель прислала update без единого поля — менять нечего, но задача
      // всё равно «затронута»: бот покажет по ней карточку, как и раньше.
      affected.push({ type: "update", task: existing });
      continue;
    }

    const [updated] = await sql<TaskRow[]>`
      update tasks set ${sql(updates)} where id = ${existing.id} returning *
    `;
    affected.push({ type: "update", task: updated });
  }

  return affected;
}

/// Момент дедлайна задачи из пары «дата + время».
///
/// Без времени берётся 23:59 — задача с датой, но без часа, наступает в конце
/// своего дня, а не в полночь его начала. Возвращает null, если даты нет или
/// она в неожиданном формате: будильник по такой задаче просто не ставится.
export function parseTaskDateTime(
  dueDate: string | null,
  dueTime: string | null,
): Date | null {
  if (!dueDate) return null;
  const dateParts = dueDate.split(".");
  const timeParts = (dueTime || "23:59").split(":");
  if (dateParts.length !== 3 || timeParts.length < 2) return null;

  const [day, month, year] = dateParts.map((p) => Number.parseInt(p, 10));
  const [hour, minute] = timeParts.map((p) => Number.parseInt(p, 10));
  if ([day, month, year, hour, minute].some((n) => Number.isNaN(n))) return null;

  return new Date(Date.UTC(year, month - 1, day, hour, minute));
}
