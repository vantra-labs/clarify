/// Замок для служебных маршрутов: напоминания по расписанию, диагностика бота,
/// переустановка вебхука.
///
/// Диагностика в проде без замка остаётся дверью: без него /telegram/reset-webhook
/// был бы готовой кнопкой «сломать бота» для любого желающего (сбрасывает очередь
/// апдейтов), а /telegram/test-support-chat — спамом в рабочий чат поддержки и
/// утечкой его идентификатора.
import { env } from "./env.ts";
import { HttpError, secretMatches } from "./http.ts";

export function requireInternalToken(req: Request): void {
  const expected = env("INTERNAL_PUSH_TOKEN");
  if (!expected) throw new HttpError(500, "INTERNAL_PUSH_TOKEN не настроен");
  if (!secretMatches(req.headers.get("x-internal-token"), expected)) {
    throw new HttpError(401, "Неверный токен");
  }
}
