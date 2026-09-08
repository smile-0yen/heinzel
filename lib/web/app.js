"use strict";
/* app.js — heinzel の運行図表。
 *
 * 判定はここで作らない。`hzl dashboard` が返した事実を並べ替えて描くだけで、
 * 「動いている/止まっている」の根拠は必ず画面の上に一緒に出す。分からないことは
 * 分からないまま出す（—）。緑を作るために欠落を成功として扱わない。 */

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

let STATE = null;
let FETCHED_AT = 0;

/* ── 表示語彙 ──────────────────────────────────────────
 * 色は 3 つだけ。平常運転には色を与えない。琥珀は明モードで contrast が
 * 3:1 に届かないので、chip は必ずグリフと文字を併記する。 */
const MARKER = {
  " ": { tone: "calm",    glyph: "·", text: "待機" },
  "~": { tone: "running", glyph: "▶", text: "作業中" },
  "x": { tone: "calm",    glyph: "✓", text: "完了" },
  "X": { tone: "calm",    glyph: "✓", text: "完了" },
  "!": { tone: "bad",     glyph: "⛔", text: "あなた待ち" },
};
const mk = (m) => MARKER[m] || { tone: "calm", glyph: "·", text: m || "—" };
const chip = (v, extra) =>
  `<span class="chip" data-tone="${v.tone}"${extra || ""}>` +
  `<span class="g" aria-hidden="true">${v.glyph}</span>${esc(v.text)}</span>`;

/* ── 時刻 ──────────────────────────────────────────────
 * launchd の StartCalendarInterval はこの端末のローカル時刻で書かれていて、
 * ledger の ISO8601 もオフセット付きで書かれている。端末のロケール任せにすると
 * 「どの時計で見ているか」が画面から消えるので、ブラウザのタイムゾーンで
 * 揃えたうえで、絶対時刻には必ず日付を添える。 */
const p2 = (n) => String(n).padStart(2, "0");
const D = (v) => {
  if (v == null || v === "") return null;
  const t = typeof v === "number" ? new Date(v * 1000) : new Date(v);
  return Number.isNaN(t.getTime()) ? null : t;
};
function tHM(v) { const d = D(v); return d ? `${p2(d.getHours())}:${p2(d.getMinutes())}` : "—"; }
function tMDHM(v) {
  const d = D(v);
  return d ? `${d.getMonth() + 1}/${d.getDate()} ${p2(d.getHours())}:${p2(d.getMinutes())}` : "—";
}
function fmtAge(sec) {
  if (sec == null) return "—";
  const s = Math.abs(Math.round(sec));
  if (s < 60) return `${s}秒`;
  if (s < 3600) return `${Math.floor(s / 60)}分`;
  if (s < 86400) {
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    return m ? `${h}時間${m}分` : `${h}時間`;
  }
  return `${Math.floor(s / 86400)}日`;
}

/* ── 鮮度 ──────────────────────────────────────────────
 * 収集に失敗したときは、古い値を新しい顔で出さない。画面を灰色に落として、
 * いつのデータなのかを常にヘッダへ刻む。 */
function renderFreshness(err) {
  const b = $("banner");
  const age = FETCHED_AT ? (Date.now() - FETCHED_AT) / 1000 : null;
  const host = STATE ? STATE.host : "";
  $("meta").innerHTML = STATE
    ? `${esc(host)} · hzl ${esc(STATE.version)}<br>データ ${esc(fmtAge(age))}前`
    : "読み込み中";
  document.body.dataset.stale = err ? "true" : "false";
  if (err) {
    b.dataset.level = "crit";
    b.textContent = `いまの状態を取れなかった: ${err}` +
      (STATE ? "（下に出ているのは前回の値。新しくはない）" : "");
  } else {
    b.removeAttribute("data-level");
    b.textContent = "";
  }
}

/* ── 判定 ──────────────────────────────────────────────
 * この画面でいちばん大きい文字。断定できることだけを書き、根拠を副題に置く。 */
function renderVerdict(s) {
  const el = $("verdict");
  const sess = s.session || {};
  const blocked = s.tasks.filter((t) => t.marker === "!").length;
  const todo = s.tasks.filter((t) => t.marker === " ").length;
  let tone = "", glyph = "✓", title, sub;

  if (!s.schedule.agent_loaded) {
    tone = "bad"; glyph = "⛔";
    title = "予定が入っていない";
    sub = "launchd に agent が積まれていない。`hzl install` を実行するまで、何時になっても走らない。";
  } else if (sess.halt_reason) {
    tone = "bad"; glyph = "⛔";
    title = "止められている";
    sub = `${sess.halt_reason} — 直したら \`hzl resume\``;
  } else if (sess.mode === "off") {
    tone = "late"; glyph = "⏸";
    title = "セッションが開いていない";
    sub = `${sess.reason || "—"} — 予定の時刻は来るが、run は gate 1 で止まる。\`hzl work\` で開く。`;
  } else if (todo === 0) {
    title = "開いている。積むものがない";
    sub = `次は ${tMDHM(s.schedule.next_run)}。待機 0 件なので、その run は「nothing to do」で終わる。`;
  } else {
    title = "開いている";
    sub = `次は ${tMDHM(s.schedule.next_run)}。待機 ${todo} 件。`;
  }
  if (blocked > 0 && !tone) { tone = "late"; glyph = "⚑"; }
  el.dataset.tone = tone;
  el.innerHTML = `<div class="g" aria-hidden="true">${glyph}</div>
    <div><div class="t">${esc(title)}</div><div class="s">${esc(sub)}` +
    (blocked ? ` あなた待ちが ${blocked} 件。` : "") + `</div></div>`;
}

function renderSession(s) {
  const q = s.session || {};
  const lr = q.last_run;
  const rows = [
    ["モード", q.mode !== "off" ? `${q.mode}（${tMDHM(q.expires_at)} まで）` : `off — ${q.reason || "—"}`],
    ["予算", `${q.tasks_done_total ?? "—"} / ${q.max_tasks_total ?? "—"} 件`],
    ["次の run", `${tMDHM(s.schedule.next_run)}`],
    ["予定", `${esc(s.schedule.display)} 時（毎正時）`],
    ["最短間隔", s.schedule.min_gap_sec > 0 ? `${s.schedule.min_gap_sec} 秒` : "なし"],
    ["姿勢", q.posture || "—"],
    ["電源", q.sleep_disabled === "1" ? "スリープ抑止中" : "抑止していない"],
    ["直近の run", lr ? `${lr.run_id} ${lr.result} — ${lr.tasks_done} 完了 / ${lr.tasks_blocked} 保留` : "記録なし"],
    ["エンジン", `${s.engines.executor}（${s.engines.model || "既定"}）` +
      (s.engines.reviewer ? ` / review: ${s.engines.reviewer}` : " / review なし")],
    ["backlog", s.backlog],
  ];
  $("session").innerHTML = rows
    .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("");
}

function renderWorkspaces(s) {
  $("n-ws").textContent = s.workspaces.length;
  $("ws").innerHTML = s.workspaces.map((w) => {
    const v = w.exists
      ? { tone: "calm", glyph: "✓", text: w.default ? "既定" : "あり" }
      : { tone: "bad", glyph: "✕", text: "ない" };
    const n = s.tasks.filter((t) => t.workspace === w.name && t.marker === " ").length;
    return `<div class="row">${chip(v)}
      <div class="nm">${esc(w.name)}</div>
      <div class="foot"><span class="sub mono">${esc(w.path)}</span>
      <span class="sub">待機 ${n}</span></div></div>`;
  }).join("") || `<div class="row"><div class="nm muted">設定なし</div></div>`;
}

function renderBlocked(s) {
  const rows = s.tasks.filter((t) => t.marker === "!");
  $("n-blocked").textContent = rows.length;
  if (!rows.length) {
    $("blocked").innerHTML = `<div class="card"><div class="b muted">あなた待ちはない。</div></div>`;
    return;
  }
  const card = (t) => `
    <div class="card" data-tone="late">
      <div class="h">${chip({ tone: "late", glyph: "⛔", text: t.id || "id なし" })}
        <span>${esc(t.text)}</span></div>
      <div class="b">${esc(t.reason || "理由の記録なし")}</div>
      <div class="act">${esc(t.workspace)} · ${t.blocked_at ? esc(t.blocked_at.slice(0, 10)) : "日付なし"}
        ${t.id ? `· <span class="mono">hzl take ${esc(t.id)}</span>` : ""}</div>
    </div>`;
  // 先頭 4 件だけを開いて出し、残りは畳む。畳むだけで、一覧から外しはしない
  // ——ここに出ない対象が個別の経路でしか読めない、という状態を作らないため。
  // 理由の長い依頼が 9 件並ぶと、その下にある待ち行列と運行図表が画面の外へ
  // 押し出され、「次に何が走るか」を見に来た人が延々とスクロールすることになる。
  const HEAD = 4;
  $("blocked").innerHTML = rows.slice(0, HEAD).map(card).join("") +
    (rows.length > HEAD ? `<details><summary>残り ${rows.length - HEAD} 件</summary>
      <div class="inner">${rows.slice(HEAD).map(card).join("")}</div></details>` : "");
}

function renderQueue(s) {
  const rows = s.tasks
    .filter((t) => t.marker === " " || t.marker === "~")
    .sort((a, b) => a.priority - b.priority || a.line - b.line);
  $("n-queue").textContent = rows.length;
  // このセッションが持っていないチェックアウトを名指しているタスクは、次の run が
  // 拾って `[!]` に落とす。積んだ人には理由が分からないまま消えるので、走る前に
  // ここで言う——「どこで走るか」は待ち行列のいちばん大事な属性になった。
  const have = new Set(s.workspaces.map((w) => w.name));
  $("queue").innerHTML = rows.map((t, i) => {
    const ok = have.has(t.workspace);
    return `<div class="row">${chip(ok ? mk(t.marker) : { tone: "bad", glyph: "⛔", text: "行き先なし" })}
      <div class="nm">${esc(t.text)}</div>
      <div class="foot">
        <span class="sub">P${t.priority} · ${esc(t.workspace)}${ok ? "" : "（このセッションにはない）"} · ${esc(t.id || "id は run が採番")}</span>
        <span class="sub">${i === 0 && ok ? "次に着手" : ""}</span>
      </div></div>`;
  }).join("") ||
    `<div class="row"><div class="nm muted">待機している仕事はない。</div></div>`;
  $("legend").innerHTML = [
    ["calm", "·", "待機"], ["running", "▶", "作業中"], ["bad", "⛔", "あなた待ち"],
  ].map(([tone, g, t]) => `<span>${chip({ tone, glyph: g, text: t })}</span>`).join("");
}

/* ── 運行図表 ──────────────────────────────────────────
 * 横軸が時刻、縦軸が run の段階。予定の枠は破線、実際に走った run は
 * イベントの時刻を結んだ実線。予定はあったのに線が無いところが「運休」で、
 * この画面がいちばん見せたいのはそこ。 */
const STAGES = ["queued", "engine", "review", "merged", "ended"];
const STAGE_LABEL = { queued: "受付", engine: "実行", review: "点検", merged: "台帳", ended: "終了" };
const STAGE_OF = {
  "run.queued": 0, "engine.started": 1, "workspace.frozen": 2,
  "review.done": 2, "worksheet.merged": 3, "run.ended": 4,
};

function renderDiagram(s) {
  if (!$("d-diagram").open) return;
  const svg = $("diagram");
  const now = Date.now();
  const slots = s.schedule.slots.map((x) => x.epoch * 1000);
  let runs = s.runs.map((r) => ({
    id: r.id,
    pts: r.events.map((e) => ({ t: D(e.at)?.getTime(), st: STAGE_OF[e.kind] })).
      filter((p) => p.t != null && p.st != null),
    ended: (r.events.find((e) => e.kind === "run.ended") || {}).message || "",
  })).filter((r) => r.pts.length);

  // 窓は予定の枠が張る範囲。run の記録は何日分も残っているので、いちばん古い run
  // に合わせると横軸が数日に伸び、いま見たい時間帯が図の右端の外へ出る——最初に
  // 目に入るのが 5 日前の夜になる。窓を決めてから、その中の run だけを描く。
  const t0 = Math.min(...slots, now - 3600e3);
  const t1 = Math.max(...slots, now + 3600e3);
  runs = runs.filter((r) => r.pts[r.pts.length - 1].t >= t0 && r.pts[0].t <= t1);
  const PAD = { l: 44, r: 18, t: 20, b: 28 };
  const W = Math.max(900, Math.round((t1 - t0) / 3600e3) * 34 + PAD.l + PAD.r);
  const H = 210;
  const x = (ms) => PAD.l + ((ms - t0) / (t1 - t0)) * (W - PAD.l - PAD.r);
  const y = (st) => PAD.t + (st / (STAGES.length - 1)) * (H - PAD.t - PAD.b);
  const parts = [];

  // 目盛は正時。6 時間ごとを主目盛にして、深夜帯が読めるようにする。
  for (let d = new Date(t0), ms = d.setMinutes(0, 0, 0); ms < t1; ms += 3600e3) {
    const h = new Date(ms).getHours();
    const major = h % 6 === 0;
    parts.push(`<line x1="${x(ms).toFixed(1)}" y1="${PAD.t}" x2="${x(ms).toFixed(1)}"
      y2="${H - PAD.b}" stroke="var(--rule)" stroke-width="${major ? 1 : 0.5}"
      ${major ? "" : 'stroke-dasharray="2 4"'} opacity="${major ? 0.9 : 0.45}"/>`);
    if (major) parts.push(`<text x="${x(ms).toFixed(1)}" y="${H - PAD.b + 15}"
      fill="var(--ink-3)" font-size="10" text-anchor="middle">${h}時</text>`);
  }
  STAGES.forEach((name, i) => {
    parts.push(`<line x1="${PAD.l - 4}" y1="${y(i).toFixed(1)}" x2="${W - PAD.r}"
      y2="${y(i).toFixed(1)}" stroke="var(--rule)" stroke-width="0.5" opacity="0.5"/>`);
    parts.push(`<text x="${PAD.l - 8}" y="${y(i) + 3}" fill="var(--ink-3)" font-size="9"
      text-anchor="end">${STAGE_LABEL[name]}</text>`);
  });

  // 予定の枠。走ったかどうかとは別に、まず「予定はあった」を描く。
  slots.forEach((ms) => {
    const ran = runs.some((r) => Math.abs(r.pts[0].t - ms) < 30 * 60e3);
    parts.push(`<path d="M ${x(ms).toFixed(1)} ${y(0).toFixed(1)}
      L ${x(ms + 20 * 60e3).toFixed(1)} ${y(4).toFixed(1)}" fill="none"
      stroke="var(--plan)" stroke-width="1" stroke-dasharray="3 3" opacity="0.8"/>`);
    if (!ran && ms < now) {
      // 予定はあったが run の記録がない。gate で止まった回はここに落ちる。
      parts.push(`<text x="${x(ms).toFixed(1)}" y="${y(2) + 4}" fill="var(--ink-3)"
        font-size="11" text-anchor="middle" opacity="0.85">·</text>`);
    } else if (!ran) {
      parts.push(`<circle cx="${x(ms).toFixed(1)}" cy="${y(0).toFixed(1)}" r="3"
        fill="none" stroke="var(--plan)" stroke-width="1.2"/>`);
    }
  });

  runs.forEach((r) => {
    // `run.ended` は「<結果> review=<判定> N done, M blocked」。M は台帳全体の
    // 保留数であって、この run の良し悪しではない——文字列に blocked が含まれる
    // かどうかで色を決めると、平常運転の夜が毎回琥珀になる（実際になった）。
    // 結果そのものと review の判定だけを読む。
    const result = (r.ended.split(/\s+/)[0] || "").toLowerCase();
    const review = (r.ended.match(/review=([a-z-]+)/i) || [])[1] || "";
    const tone = (result === "error" || /HALT/.test(r.ended)) ? "var(--bad)"
      : /^(reject|revise|failed)$/.test(review) ? "var(--late)"
      : "var(--ink-2)";
    const pts = r.pts.map((p) => `${x(p.t).toFixed(1)},${y(p.st).toFixed(1)}`).join(" ");
    parts.push(`<polyline points="${pts}" fill="none" stroke="${tone}" stroke-width="2.5"
      stroke-linejoin="round" stroke-linecap="round"><title>${esc(r.id)} ${esc(r.ended)}</title></polyline>`);
  });

  parts.push(`<line x1="${x(now).toFixed(1)}" y1="${PAD.t - 9}" x2="${x(now).toFixed(1)}"
    y2="${H - PAD.b}" stroke="var(--running)" stroke-width="1.5"/>`);
  parts.push(`<text x="${x(now).toFixed(1)}" y="${PAD.t - 11}" fill="var(--running)"
    font-size="10" text-anchor="middle">現在</text>`);

  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  svg.setAttribute("width", W);
  svg.setAttribute("height", H);
  svg.innerHTML = parts.join("\n");
  // 図が枠より広いときは「現在」が見える位置から開く。左端から開くと、狭い画面では
  // 最初に出るのが窓のいちばん古い端になる。
  const wrap = $("diagram-wrap");
  wrap.scrollLeft = Math.max(0, x(now) - wrap.clientWidth * 0.72);
  const missed = slots.filter((ms) => ms < now &&
    !runs.some((r) => Math.abs(r.pts[0].t - ms) < 30 * 60e3)).length;
  $("diagram-note").textContent =
    `破線が予定の枠、実線が実際に走った run。${missed} 回は予定があって run の記録がない` +
    `（gate で止まった回。理由は runner.log の skip 行）。`;
}

function renderRuns(s) {
  $("n-runs").textContent = s.runs.length;
  $("runs").innerHTML = `<table><thead><tr>
      <th>run</th><th>始</th><th>終</th><th>結果</th></tr></thead><tbody>` +
    s.runs.map((r) => {
      const first = r.events[0], last = r.events[r.events.length - 1];
      const ended = (r.events.find((e) => e.kind === "run.ended") || {}).message || "—";
      return `<tr><td class="mono">${esc(r.id)}</td>
        <td>${esc(tMDHM(first && first.at))}</td>
        <td>${esc(tHM(last && last.at))}</td>
        <td>${esc(ended)}</td></tr>`;
    }).join("") + `</tbody></table>`;
}

function renderAll() {
  if (!STATE) return;
  renderVerdict(STATE);
  renderSession(STATE);
  renderWorkspaces(STATE);
  renderBlocked(STATE);
  renderQueue(STATE);
  renderRuns(STATE);
  renderDiagram(STATE);
  const sel = $("add-ws");
  const keep = sel.value;
  sel.innerHTML = STATE.workspaces.map((w) =>
    `<option value="${esc(w.name)}">${esc(w.name)}${w.default ? "（既定）" : ""}</option>`).join("");
  if (keep) sel.value = keep;
}

async function load() {
  const btn = $("btn-refresh");
  btn.disabled = true;
  try {
    const r = await fetch("/api/dashboard", { headers: { Accept: "application/json" } });
    const body = await r.json();
    if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
    STATE = body;
    FETCHED_AT = Date.now();
    renderFreshness(null);
    renderAll();
  } catch (e) {
    renderFreshness(e.message || String(e));
  } finally {
    btn.disabled = false;
  }
}

$("btn-refresh").addEventListener("click", load);
$("d-diagram").addEventListener("toggle", () => renderDiagram(STATE));
$("btn-theme").addEventListener("click", () => {
  const now = document.documentElement.dataset.theme;
  const next = now === "dark" ? "light" : now === "light" ? "auto" : "dark";
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem("heinzel.theme", next); } catch (e) { /* private window */ }
});
try {
  const saved = localStorage.getItem("heinzel.theme");
  if (saved) document.documentElement.dataset.theme = saved;
} catch (e) { /* private window */ }

$("add-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const said = $("add-said");
  const btn = $("add-send");
  const text = $("add-text").value.trim();
  if (!text) return;
  btn.disabled = true;
  said.removeAttribute("data-tone");
  said.textContent = "積んでいる…";
  try {
    // application/json は、この経路を preflight の要る要求にするためでもある。
    // 別サイトのフォームからは同じ要求を作れない。
    const r = await fetch("/api/task", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text, priority: Number($("add-prio").value), workspace: $("add-ws").value,
      }),
    });
    const body = await r.json();
    if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
    said.textContent = "積んだ。";
    $("add-text").value = "";
    await load();
  } catch (e) {
    said.dataset.tone = "bad";
    said.textContent = `積めなかった: ${e.message || e}`;
  } finally {
    btn.disabled = false;
  }
});

renderFreshness(null);
load();
