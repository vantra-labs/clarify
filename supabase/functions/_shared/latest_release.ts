// Последняя версия десктопного приложения — из GitHub Releases.
//
// Раньше версия, ссылка и описание жили в секретах функции
// (LATEST_APP_VERSION и т.д.), и каждый выпуск требовал руками поправить их в
// панели Supabase. Забыл — установленные копии про обновление не узнали.
// Теперь источник правды один: последний релиз vantra-labs/clarify, который
// публикует воркфлоу «Релиз для Windows». Секреты остаются запасным вариантом
// на случай, если GitHub не ответил.
//
// Кэш на 10 минут: без токена GitHub даёт 60 запросов в час с одного адреса,
// а проверку делает каждая запущенная копия приложения.

import { env } from "./env.ts";

const REPO = "vantra-labs/clarify";
const DOWNLOAD_URL = `https://github.com/${REPO}/releases/latest/download/Clarify_Setup.exe`;
const CACHE_MS = 10 * 60 * 1000;

export type LatestRelease = {
  version: string;
  url: string;
  notes: string;
  min_supported: string;
};

let cached: { at: number; value: LatestRelease } | null = null;

function fromEnv(): LatestRelease {
  return {
    version: env("LATEST_APP_VERSION"),
    url: env("LATEST_APP_URL"),
    notes: env("LATEST_APP_NOTES"),
    min_supported: env("MIN_SUPPORTED_APP_VERSION"),
  };
}

export async function latestRelease(): Promise<LatestRelease> {
  if (cached && Date.now() - cached.at < CACHE_MS) return cached.value;
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { "Accept": "application/vnd.github+json", "User-Agent": "clarify-api" },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) throw new Error(`GitHub ${res.status}`);
    const data = await res.json();
    const version = String(data.tag_name ?? "").replace(/^v/, "").trim();
    if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`странный тег ${data.tag_name}`);
    const value: LatestRelease = {
      version,
      url: DOWNLOAD_URL,
      notes: String(data.body ?? "").trim().slice(0, 600),
      // Нижнюю границу по-прежнему задаёт человек, а не релиз: это решение
      // «старые версии больше не работают», его не принимают автоматически.
      min_supported: env("MIN_SUPPORTED_APP_VERSION"),
    };
    cached = { at: Date.now(), value };
    return value;
  } catch (e) {
    console.warn("latestRelease: GitHub недоступен, беру секреты:", e);
    return fromEnv();
  }
}
