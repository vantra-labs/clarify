/// Имя пользователя для подстановки в уведомления и пересылку в поддержку.
import { sql } from "./db.ts";

/// Реальный PK таблицы profiles — user_id, а не id.
///
/// Ошибку глотаем намеренно: имя — не критичная деталь, и она не стоит того,
/// чтобы из-за неё ломался весь сценарий. Раньше сбой этого запроса ронял
/// создание тикета поддержки целиком, и человек не получал вообще ничего — ни
/// пересылки вопроса, ни подтверждения.
export async function getProfileName(userId: string | null | undefined): Promise<string> {
  if (!userId) return "Пользователь";
  try {
    const [row] = await sql<{ full_name: string | null }[]>`
      select full_name from profiles where user_id = ${userId} limit 1
    `;
    return row?.full_name || "Пользователь";
  } catch (e) {
    console.warn(`[profiles] не удалось получить имя профиля: ${e}`);
    return "Пользователь";
  }
}
