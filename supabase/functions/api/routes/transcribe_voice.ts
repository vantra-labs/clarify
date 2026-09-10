/// Расшифровка голосового сообщения для ИИ-ассистента в самом приложении
/// (десктоп и мобильный чат).
///
/// Формат файла для Groq не важен (ogg/webm/m4a/wav), поэтому имя и тип нужны
/// только чтобы он правильно определил контейнер — и чтобы в логах было видно,
/// что именно прислали.
import { getCurrentUserId } from "../../_shared/auth.ts";
import { HttpError, json } from "../../_shared/http.ts";
import { transcribeVoice } from "../../_shared/groq.ts";

export async function transcribeVoiceRoute(req: Request): Promise<Response> {
  await getCurrentUserId(req);

  const form = await req.formData().catch(() => null);
  const file = form?.get("file");
  if (!(file instanceof File)) throw new HttpError(422, "Не передан файл");
  if (file.size === 0) throw new HttpError(400, "Пустой аудиофайл");

  try {
    const text = await transcribeVoice(
      file,
      file.name || "voice.webm",
      file.type || "audio/webm",
    );
    return json(req, { text });
  } catch (e) {
    throw new HttpError(502, `Не удалось расшифровать голосовое сообщение: ${e}`);
  }
}
