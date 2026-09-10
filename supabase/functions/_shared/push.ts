/// Отправка веб-пушей подписчикам.
///
/// Ключи VAPID остаются ТЕ ЖЕ, что были на прежнем бэкенде, и это не мелочь:
/// подписка браузера намертво привязана к публичному ключу, которым её создали.
/// Сгенерировать при переезде новую пару значит разом отвязать все уже
/// оформленные подписки — люди перестали бы получать уведомления и не узнали
/// бы об этом, пока не подписались бы заново.
///
/// Формат хранения при этом пришлось перевести: pywebpush принимал ключ сырой
/// base64url-строкой, а Web Crypto — только JWK. Это пересборка одного и того
/// же ключа, а не новый ключ.
import * as webpush from "jsr:@negrel/webpush@^0.5.0";
import { env } from "./env.ts";
import { sql } from "./db.ts";

/// Контакт в claims VAPID — им push-сервис ругается на отправителя, если что-то
/// пойдёт не так. Заглушка досталась с прежнего бэкенда; заменить на реальный
/// адрес стоит, но это не влияет на доставку.
const VAPID_SUBJECT = env("VAPID_SUBJECT") || "mailto:support@clarify.app";

/// Публичный ключ не секрет: он и так лежит в собранном приложении
/// (AppConfig.vapidPublicKey) и уходит в браузер при подписке. Значение по
/// умолчанию — ровно оно же, чтобы не заводить лишний секрет ради публичного
/// значения, но переопределить через окружение можно.
const VAPID_PUBLIC_KEY = env("VAPID_PUBLIC_KEY") ||
  "BE4cKKSz5qpsnfM-3IxlH7n7UFyZSfslZyFnBtxSHux0Rfhbsi5wUb4KoR4yR5HwYW7Y3z9sHjUwPC_R9OcHjdQ";

interface PushSubscriptionRow {
  endpoint: string;
  p256dh: string;
  auth_key: string;
}

function base64UrlDecode(value: string): Uint8Array {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

function base64UrlEncode(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/// Собирает пару JWK из ключей в том виде, в каком они лежали на Render.
///
/// Публичный ключ — несжатая точка кривой P-256: байт 0x04, затем 32 байта X и
/// 32 байта Y. Приватный — те самые 32 байта скаляра d.
function buildVapidJwks(): webpush.ExportedVapidKeys {
  const privateRaw = env("VAPID_PRIVATE_KEY");
  if (!privateRaw) throw new Error("VAPID_PRIVATE_KEY не настроен");
  if (privateRaw.includes("BEGIN")) {
    // pywebpush принимал и PEM. Здесь такой ключ надо сначала перевести в
    // JWK — молча продолжать нельзя, иначе push тихо не уйдёт ни одному
    // человеку, а в логах будет только «ошибка отправки».
    throw new Error("VAPID_PRIVATE_KEY в формате PEM не поддерживается — нужен base64url");
  }

  const publicBytes = base64UrlDecode(VAPID_PUBLIC_KEY);
  if (publicBytes.length !== 65 || publicBytes[0] !== 0x04) {
    throw new Error("VAPID_PUBLIC_KEY не похож на несжатую точку P-256");
  }
  const x = base64UrlEncode(publicBytes.slice(1, 33));
  const y = base64UrlEncode(publicBytes.slice(33, 65));

  const privateBytes = base64UrlDecode(privateRaw);
  if (privateBytes.length !== 32) {
    throw new Error("VAPID_PRIVATE_KEY не похож на 32-байтовый ключ P-256");
  }
  const d = base64UrlEncode(privateBytes);

  return {
    publicKey: { kty: "EC", crv: "P-256", x, y },
    privateKey: { kty: "EC", crv: "P-256", x, y, d },
  };
}

let applicationServer: webpush.ApplicationServer | null = null;

async function getApplicationServer(): Promise<webpush.ApplicationServer> {
  if (applicationServer) return applicationServer;
  const vapidKeys = await webpush.importVapidKeys(buildVapidJwks(), { extractable: false });
  applicationServer = await webpush.ApplicationServer.new({
    contactInformation: VAPID_SUBJECT,
    vapidKeys,
  });
  return applicationServer;
}

/// Шлёт push всем подпискам одного пользователя. Возвращает число успешных
/// отправок.
///
/// Ошибки ловятся широко и по каждой подписке отдельно: одна протухшая подписка
/// или один сбойный ключ не должны обрывать рассылку остальным.
export async function sendWebPushToUser(
  userId: string | null,
  title: string,
  body: string,
): Promise<number> {
  if (!userId) return 0;

  const subs = await sql<PushSubscriptionRow[]>`
    select endpoint, p256dh, auth_key from push_subscriptions where user_id = ${userId}
  `;
  if (subs.length === 0) return 0;

  let server: webpush.ApplicationServer;
  try {
    server = await getApplicationServer();
  } catch (e) {
    // Сюда попадают только поломки настройки (нет ключа, ключ не того формата).
    // Это касается всех подписок разом, поэтому и сообщение одно.
    console.error(`[push] отправка невозможна: ${e}`);
    return 0;
  }

  // JSON.stringify, а не сборка строки руками: кавычки и переносы в названии
  // задачи иначе ломают полезную нагрузку.
  const payload = JSON.stringify({ title, body });

  let sent = 0;
  for (const sub of subs) {
    try {
      const subscriber = server.subscribe({
        endpoint: sub.endpoint,
        keys: { auth: sub.auth_key, p256dh: sub.p256dh },
      });
      await subscriber.pushTextMessage(payload, {});
      sent++;
    } catch (e) {
      console.warn(`[push] ошибка отправки: ${e}`);
    }
  }
  return sent;
}
