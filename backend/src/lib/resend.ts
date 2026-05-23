// Resend API への薄い fetch ラッパー。
// 必要なのは「メール 1 通送る」だけなので 1 関数で済む。
// RESEND_ENABLED=false の場合は noop (ローカル開発 + API key 無しでも壊れない)。

export type ResendEmail = {
  from: string;
  to: string;
  subject: string;
  html: string;
  text: string;
};

export class ResendApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "ResendApiError";
  }
}

export async function sendEmail(
  apiKey: string | undefined,
  enabled: boolean,
  email: ResendEmail
): Promise<{ id: string } | null> {
  if (!enabled || !apiKey || apiKey.startsWith("re_placeholder")) {
    console.log(`[resend disabled] would send to=${email.to} subject="${email.subject}"`);
    return null;
  }
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(email),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new ResendApiError(res.status, `Resend send failed: ${res.status} ${text}`);
  }
  return (await res.json()) as { id: string };
}
