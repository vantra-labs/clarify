/// Вход через Яндекс: обмен одноразового кода OAuth на сессию Supabase.
///
/// Это тот самый маршрут, из-за которого приложение не пускало людей внутрь,
/// когда Render перестал открываться из России: код от Яндекса ловил клиент, а
/// обменять его было негде — Supabase был доступен, а средний шаг лежал на
/// заблокированном хосте.
import { HttpError, json } from "../../_shared/http.ts";
import {
  env,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
  supabaseAdminHeaders,
} from "../../_shared/env.ts";

/// Client ID приложения в Яндекс OAuth — не секрет, он и так уезжает в
/// собранный exe (AppConfig.yandexClientId) и виден в адресной строке при
/// входе. Секрет — только YANDEX_CLIENT_SECRET.
const YANDEX_CLIENT_ID = env("YANDEX_CLIENT_ID") || "8a185fbf29224afa926cdfc55e78c7ad";

interface YandexUserInfo {
  default_email?: string;
  id?: string;
}

/// Создаёт пользователя Supabase под этой почтой, если его ещё нет.
///
/// Пароль не задаётся вообще: вход через Яндекс идёт одноразовым токеном
/// (см. issueMagiclinkTokenHash), пароль в этой схеме не нужен и потому не
/// должен существовать.
async function ensureSupabaseUser(email: string, yandexUserId: string): Promise<void> {
  const resp = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    method: "POST",
    headers: supabaseAdminHeaders(),
    body: JSON.stringify({
      email,
      email_confirm: true,
      user_metadata: { auth_source: "yandex", yandex_user_id: String(yandexUserId) },
    }),
  });
  if (resp.status === 200 || resp.status === 201) return;

  // Пользователь уже есть — нормальный путь для всех входов, кроме первого.
  const body = (await resp.text()).toLowerCase();
  if (
    (resp.status === 409 || resp.status === 422) &&
    (body.includes("already") || body.includes("exists") || body.includes("registered"))
  ) {
    return;
  }
  throw new HttpError(502, `Supabase не создал пользователя: ${resp.status} ${body}`);
}

/// Гасит старый вычислимый пароль у аккаунта и помечает его как Яндекс-вход.
///
/// Аккаунты, созданные прежней схемой, до сих пор принимают пароль по формуле
/// "Yndx_<yandex_id>_SecretPass123!". Сессию мы выдаём без пароля, поэтому при
/// ПЕРВОМ входе через Яндекс ставим случайный: аккаунт закрывается сам, без
/// ручной миграции, как только человек войдёт хотя бы раз.
///
/// Метка auth_source=yandex ставится здесь, а не только при создании аккаунта:
/// у заведённых прежней схемой её нет вовсе, и приложение не может отличить их
/// от обычных «почта+пароль». А отличать надо — иначе в настройках им
/// предлагается «Изменить пароль» с запросом текущего, которого они никогда не
/// знали (B8).
///
/// Метаданные сливаются, а не перезаписываются: PUT с user_metadata заменяет
/// объект целиком, и без слияния мы бы затёрли имя и аватар.
///
/// Ошибку не поднимаем: не смогли сменить пароль — вход всё равно должен
/// состояться, это подстраховка, а не часть входа.
async function sealYandexAccount(email: string): Promise<void> {
  try {
    const listed = await fetch(
      `${SUPABASE_URL}/auth/v1/admin/users?filter=${encodeURIComponent(email)}&per_page=200`,
      { headers: supabaseAdminHeaders() },
    );
    if (listed.status !== 200) {
      console.warn(`[auth] не удалось найти пользователя для смены пароля: ${listed.status}`);
      return;
    }
    const users = (await listed.json())?.users ?? [];
    const target = users.find(
      (u: { email?: string }) => (u.email ?? "").toLowerCase() === email.toLowerCase(),
    );
    if (!target) {
      console.warn("[auth] пользователь для смены пароля не найден в ответе Supabase");
      return;
    }

    const metadata: Record<string, unknown> = { ...(target.user_metadata ?? {}) };

    // Пароль гасим ОДИН раз за всё время, а не на каждом входе.
    //
    // Смена пароля в GoTrue отзывает refresh-токены пользователя. Пока это
    // делалось на каждом входе через Яндекс, любой вход выкидывал человека со
    // всех остальных устройств: зашёл с телефона — разлогинился ПК, и наоборот.
    // Молча, без единого сообщения. Поймано живой проверкой 06.09.2026.
    //
    // Одного раза достаточно и по смыслу: старый вычислимый пароль после первой
    // замены мёртв навсегда, гасить повторно уже нечего.
    const alreadySealed = Boolean(metadata.yandex_sealed);
    if (alreadySealed && metadata.auth_source === "yandex") return;

    metadata.auth_source = "yandex";
    metadata.yandex_sealed = true;

    const payload: Record<string, unknown> = { user_metadata: metadata };
    if (!alreadySealed) payload.password = randomPassword();

    const updated = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${target.id}`, {
      method: "PUT",
      headers: supabaseAdminHeaders(),
      body: JSON.stringify(payload),
    });
    if (updated.status !== 200) {
      console.warn(`[auth] смена пароля не прошла: ${updated.status} ${await updated.text()}`);
    }
  } catch (e) {
    console.warn(`[auth] смена пароля не прошла (сеть): ${e}`);
  }
}

/// Случайный пароль взамен старого вычислимого. 48 байт из системного
/// генератора — его никто не должен знать и никогда не вводит, это заглушка
/// вместо предсказуемой строки.
function randomPassword(): string {
  const bytes = new Uint8Array(48);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// Одноразовый токен входа для уже проверенного Яндексом пользователя.
///
/// generate_link НЕ отправляет письмо — он только возвращает hashed_token,
/// который клиент меняет на сессию через verifyOTP. Ссылка (action_link) нам не
/// нужна и никуда не уходит.
async function issueMagiclinkTokenHash(email: string): Promise<string> {
  const resp = await fetch(`${SUPABASE_URL}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: supabaseAdminHeaders(),
    body: JSON.stringify({ type: "magiclink", email }),
  });
  if (resp.status !== 200) {
    throw new HttpError(502, `Supabase не выдал токен входа: ${resp.status} ${await resp.text()}`);
  }
  const data = await resp.json();
  // В разных версиях GoTrue поле лежит либо в properties, либо в корне.
  const tokenHash = data?.properties?.hashed_token ?? data?.hashed_token;
  if (!tokenHash) throw new HttpError(502, "Supabase вернул ответ без hashed_token");
  return tokenHash as string;
}

export async function authYandex(req: Request): Promise<Response> {
  const clientSecret = env("YANDEX_CLIENT_SECRET");
  if (!clientSecret) throw new HttpError(500, "YANDEX_CLIENT_SECRET не настроен");
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new HttpError(500, "SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY не настроены");
  }

  const body = await req.json().catch(() => null);
  const code = body?.code;
  if (!code || typeof code !== "string") {
    throw new HttpError(422, "Не передан code");
  }

  // 1. Меняем код на токен доступа.
  const tokenResp = await fetch("https://oauth.yandex.ru/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: YANDEX_CLIENT_ID,
      client_secret: clientSecret,
    }),
  });
  const tokenJson = await tokenResp.json().catch(() => ({}));
  if (tokenJson.error) {
    throw new HttpError(401, `Ошибка Яндекса: ${JSON.stringify(tokenJson)}`);
  }
  const accessToken = tokenJson.access_token;
  if (!accessToken) {
    throw new HttpError(401, `Яндекс не вернул токен: ${JSON.stringify(tokenJson)}`);
  }

  // 2. Получаем инфу о пользователе по токену.
  const infoResp = await fetch("https://login.yandex.ru/info", {
    headers: { Authorization: `OAuth ${accessToken}` },
  });
  const userInfo: YandexUserInfo = await infoResp.json().catch(() => ({}));
  const email = userInfo.default_email;
  const yandexUserId = userInfo.id;
  if (!email) throw new HttpError(502, "Яндекс не вернул почту пользователя");

  // 3. Сессию выдаёт сервер, а не клиент: одноразовый токен вместо пароля.
  //
  // ПОРЯДОК ЗДЕСЬ КРИТИЧЕН, не переставлять. Смена пароля в GoTrue аннулирует
  // все невостребованные одноразовые токены пользователя — это правильное
  // поведение с точки зрения безопасности, но означает, что sealYandexAccount
  // обязан отработать ДО выдачи токена, а не после.
  //
  // Сначала было наоборот, и вход через Яндекс падал ВСЕГДА: сервер выдавал
  // токен и тут же сам его гасил, а клиент получал от Supabase «Email link is
  // invalid or has expired». Найдено живой проверкой 06.09.2026.
  await ensureSupabaseUser(email, String(yandexUserId ?? ""));
  await sealYandexAccount(email);
  const tokenHash = await issueMagiclinkTokenHash(email);

  return json(req, {
    ok: true,
    yandex_user_id: yandexUserId,
    email,
    token_hash: tokenHash,
    message: "Успешный вход через Яндекс!",
  });
}
