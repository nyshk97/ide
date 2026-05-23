# Resources/License

このディレクトリは EdDSA (Ed25519) **公開鍵** だけを格納する。
鍵生成は `backend/scripts/gen-license-keys.sh` を実行する (秘密鍵は dotfiles 配下に書かれる)。

公開鍵 `license-pubkey.pem` は git に commit して構わない (アプリにバンドルされる)。
秘密鍵は **絶対に** ここに置かない。
