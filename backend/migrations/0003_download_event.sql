-- download_event: appcast / download エンドポイントへのアクセスを 1 行ずつ記録する。
-- 目的は「新規インストール vs 自動更新」の区別。User-Agent を Sparkle / Homebrew / browser /
-- other に分類して classification に入れる。
--
-- 想定ボリュームは現状 100/日 オーダー。インデックスは時系列クエリ用と分類別集計用の 2 つ。
-- 長期保存しても D1 のコスト的に無視できる量なので TTL ジョブは置かない。
CREATE TABLE download_event (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at     INTEGER NOT NULL,    -- unix ms
  classification  TEXT NOT NULL,       -- 'sparkle' | 'homebrew' | 'browser' | 'curl' | 'other'
  resource        TEXT NOT NULL,       -- 'appcast' | 'download'
  version         TEXT,                -- 'v1.4.2' | 'latest' | NULL (appcast 時)
  asset           TEXT,                -- 'polepole.dmg' | 'appcast.xml' | ...
  user_agent      TEXT,
  country         TEXT
);

CREATE INDEX idx_download_event_occurred ON download_event(occurred_at);
CREATE INDEX idx_download_event_class_occurred ON download_event(classification, occurred_at);
