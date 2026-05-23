// ライセンスキー生成。`polepole-XXXX-XXXX-XXXX-XXXX` 形式。
// 紛らわしい 0/O/1/I/l を除外した大文字英数字を使う。

const ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

function randomGroup(): string {
  const bytes = new Uint8Array(4);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < 4; i++) {
    out += ALPHABET[bytes[i] % ALPHABET.length];
  }
  return out;
}

export function generateLicenseKey(): string {
  return `polepole-${randomGroup()}-${randomGroup()}-${randomGroup()}-${randomGroup()}`;
}

const KEY_PATTERN = /^polepole-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/;

export function isValidKeyFormat(key: string): boolean {
  return KEY_PATTERN.test(key);
}
