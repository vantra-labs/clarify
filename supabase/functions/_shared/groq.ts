/// Распознавание речи через Groq (Whisper).
///
/// Одна обёртка на оба канала — голосовые в самом приложении
/// (/ai/transcribe-voice) и голосовые Telegram-боту. Раздельные реализации
/// разъезжаются: у бота формат всегда OGG/Opus, у приложения — что запишет
/// Windows или браузер.
///
/// ВАЖНО: точные условия бесплатного тарифа Groq для аудио-моделей
/// документацией не подтверждены — стоит проверять лимиты в самой консоли
/// Groq, прежде чем полагаться на это в проде без ограничений.
import { requireEnv } from "./env.ts";

const GROQ_TRANSCRIPTIONS_URL = "https://api.groq.com/openai/v1/audio/transcriptions";
const MODEL = "whisper-large-v3-turbo";

/// filename/content_type по умолчанию — реальный формат голосовых Telegram.
/// Приложение передаёт настоящее имя и тип загруженного файла: Groq определяет
/// контейнер по расширению, и запись из Windows или браузера (AAC/WebM, не ogg)
/// с жёстко зашитым "voice.ogg" не расшифровалась бы.
export async function transcribeVoice(
  audio: Blob | Uint8Array,
  filename = "voice.ogg",
  contentType = "audio/ogg",
): Promise<string> {
  const apiKey = requireEnv("GROQ_API_KEY");
  const blob = audio instanceof Blob ? audio : new Blob([audio], { type: contentType });

  const form = new FormData();
  form.append("file", blob, filename);
  form.append("model", MODEL);

  const resp = await fetch(GROQ_TRANSCRIPTIONS_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
    // Голосовые бывают минутными, а Groq иногда отвечает не мгновенно. Предел
    // всё же нужен: без него зависший запрос держал бы вызов функции до
    // собственного потолка платформы.
    signal: AbortSignal.timeout(60_000),
  });

  if (!resp.ok) {
    throw new Error(`Groq ответил ${resp.status}: ${(await resp.text()).slice(0, 200)}`);
  }
  const data = await resp.json();
  const text = data?.text;
  if (typeof text !== "string") throw new Error("Groq вернул ответ без текста");
  return text;
}
