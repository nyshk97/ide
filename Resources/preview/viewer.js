(function () {
  "use strict";

  const root = document.getElementById("root");
  let pending = null;
  let ready = false;

  function escapeHtml(s) {
    return s
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function setTheme(theme) {
    // theme: "light" | "dark" | "auto"
    const light = document.getElementById("hl-light");
    const dark = document.getElementById("hl-dark");
    if (!light || !dark) return;
    const useDark =
      theme === "dark" ||
      (theme !== "light" &&
        window.matchMedia("(prefers-color-scheme: dark)").matches);
    light.disabled = useDark;
    dark.disabled = !useDark;
  }

  // ハイライト済み HTML を行単位で <span class="line"> ラップする。
  // 複数行 span（多行コメント・ヒアドキュメント等）にまたがる場合は
  // 行末で開いている span を一旦閉じ、次の行で同じ属性の span を開き直して整合を保つ。
  function wrapLines(html) {
    const lines = html.split("\n");
    const out = [];
    let openTags = []; // 例: ['<span class="hljs-comment">']
    const tagRE = /<span\b[^>]*>|<\/span>/g;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const prefix = openTags.join("");
      let cur = openTags.slice();
      let m;
      tagRE.lastIndex = 0;
      while ((m = tagRE.exec(line)) !== null) {
        if (m[0] === "</span>") {
          cur.pop();
        } else {
          cur.push(m[0]);
        }
      }
      const suffix = "</span>".repeat(cur.length);
      out.push('<span class="line">' + prefix + line + suffix + "</span>");
      openTags = cur;
    }
    // 各 .line は display:block で改行を作るため、\n は入れない（入れると二重改行になる）
    return out.join("");
  }

  function renderCode(text, lang) {
    root.className = "code";
    let html;
    try {
      if (lang && window.hljs && window.hljs.getLanguage(lang)) {
        html = window.hljs.highlight(text, { language: lang, ignoreIllegals: true }).value;
      } else if (window.hljs) {
        html = window.hljs.highlightAuto(text).value;
      } else {
        html = escapeHtml(text);
      }
    } catch (e) {
      html = escapeHtml(text);
    }
    const wrapped = wrapLines(html);
    // 行番号カラム幅を桁数に応じて可変。ファイル末尾の改行で 1 行余分に数えないよう調整。
    const lineCount = Math.max(1, html.split("\n").length - (html.endsWith("\n") ? 1 : 0));
    const digits = Math.max(2, String(lineCount).length);
    root.innerHTML =
      '<pre class="hljs" style="--ln-digits:' + digits + '"><code>' + wrapped + "</code></pre>";
    window.scrollTo(0, 0);
  }

  function renderMarkdown(text) {
    root.className = "md";
    let html;
    try {
      if (window.marked) {
        window.marked.setOptions({
          gfm: true,
          breaks: false,
          highlight: function (code, lang) {
            try {
              if (lang && window.hljs && window.hljs.getLanguage(lang)) {
                return window.hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
              }
              if (window.hljs) {
                return window.hljs.highlightAuto(code).value;
              }
            } catch (e) {}
            return escapeHtml(code);
          },
        });
        html = window.marked.parse(text);
      } else {
        html = "<pre>" + escapeHtml(text) + "</pre>";
      }
    } catch (e) {
      html = "<pre>" + escapeHtml(text) + "</pre>";
    }
    root.innerHTML = html;
    // marked v12 の highlight オプションは廃止予定なので、念のためフォールバックで再ハイライト
    if (window.hljs) {
      root.querySelectorAll("pre code").forEach(function (el) {
        if (!el.dataset.highlighted) {
          try {
            window.hljs.highlightElement(el);
          } catch (e) {}
          el.dataset.highlighted = "yes";
        }
      });
    }
    window.scrollTo(0, 0);
  }

  function renderError(message) {
    root.className = "error";
    root.textContent = message || "(error)";
  }

  function setBaseHref(href) {
    // マークダウン内の `./foo.md` 等を、元ファイルのディレクトリ基準で解決させる。
    // 切り替え時に古い base が残らないよう、毎回入れ替える。
    let base = document.getElementById("md-base");
    if (href) {
      if (!base) {
        base = document.createElement("base");
        base.id = "md-base";
        document.head.appendChild(base);
      }
      base.setAttribute("href", href);
    } else if (base) {
      base.parentNode.removeChild(base);
    }
  }

  function apply(payload) {
    if (!payload) return;
    if (payload.theme) setTheme(payload.theme);
    setBaseHref(payload.kind === "markdown" ? payload.baseHref || "" : "");
    switch (payload.kind) {
      case "markdown":
        renderMarkdown(payload.text || "");
        break;
      case "code":
        renderCode(payload.text || "", payload.lang || "");
        break;
      case "error":
        renderError(payload.text || "");
        break;
      default:
        renderError("unknown kind: " + payload.kind);
    }
  }

  window.viewer = {
    set: function (payload) {
      if (!ready) {
        pending = payload;
        return;
      }
      apply(payload);
    },
    isReady: function () {
      return ready;
    },
  };

  // marked / hljs は defer なので DOMContentLoaded を待つ
  document.addEventListener("DOMContentLoaded", function () {
    ready = true;
    if (pending) {
      const p = pending;
      pending = null;
      apply(p);
    }
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.viewerReady) {
      try {
        window.webkit.messageHandlers.viewerReady.postMessage("ready");
      } catch (e) {}
    }
  });
})();
