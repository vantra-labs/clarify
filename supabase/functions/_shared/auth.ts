/// Авторизация запросов от приложения.
///
/// JWT-секрета Supabase у функции нет (и заводить его отдельно незачем),
/// поэтому присланный клиентом токен валидируется прямым запросом к Supabase
/// Auth: если Supabase его принимает — значит он подлинный и не истёк.
///
/// Возвращаем id пользователя ИЗ ОТВЕТА Supabase, а не то, что прислал клиент
/// в теле запроса — иначе любой мог бы подставить чужой user_id (IDOR).
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "./env.ts";
import { HttpError } from "./http.ts";

export async function getCurrentUserId(req: Request): Promise<string> {
  const authorization = req.headers.get("authorization");
  if (!authorization || !authorization.startsWith("Bearer ")) {
    throw new HttpError(401, "Требуется авторизация");
  }
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    throw new HttpError(500, "SUPABASE_URL/SUPABASE_ANON_KEY не настроены");
  }

  const token = authorization.slice("Bearer ".length).trim();
  let resp: Response;
  try {
    resp = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(10_000),
    });
  } catch (e) {
    // Сетевая ошибка до Supabase — это не «неверный токен». Раньше (на FastAPI)
    // она долетала необработанным исключением и превращалась в голый 500 без
    // детали: клиент видел только код и терялся в догадках, где сломалось.
    throw new HttpError(503, `Не удалось проверить токен в Supabase: ${e}`);
  }

  if (resp.status !== 200) throw new HttpError(401, "Недействительный токен");

  const user = await resp.json().catch(() => null);
  const userId = user?.id;
  if (!userId || typeof userId !== "string") {
    throw new HttpError(401, "Недействительный токен");
  }
  return userId;
}
