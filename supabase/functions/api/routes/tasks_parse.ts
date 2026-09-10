/// Чат с ИИ-ассистентом внутри приложения.
///
/// Клиент берёт из ответа только "reply" и после этого перечитывает задачи
/// напрямую из Supabase (см. _sendToAiAssistant), но "tasks" отдаём по-прежнему
/// — форма ответа не должна поменяться под уже выпущенными сборками.
import { getCurrentUserId } from "../../_shared/auth.ts";
import { HttpError, json } from "../../_shared/http.ts";
import { type HistoryTurn, runAssistant } from "../../_shared/ai_parser.ts";
import { executeAssistantActions, fetchExistingTasksForAssistant } from "../../_shared/tasks.ts";

export async function tasksParse(req: Request): Promise<Response> {
  const userId = await getCurrentUserId(req);

  const body = await req.json().catch(() => null);
  const text = body?.text;
  if (typeof text !== "string") throw new HttpError(422, "Не передан text");
  // Последние сообщения чата, БЕЗ самого текущего text — дают ассистенту
  // контекст многоходовой переписки. Опционально: старые клиенты шлют запрос
  // без истории, и это по-прежнему рабочий вызов, просто без контекста.
  const history: HistoryTurn[] = Array.isArray(body?.history) ? body.history : [];

  const existingTasks = await fetchExistingTasksForAssistant(userId);
  const result = await runAssistant(text, existingTasks, history);
  const affected = await executeAssistantActions(userId, result.actions, text.slice(0, 20));

  return json(req, { reply: result.reply, tasks: affected.map((a) => a.task) });
}
