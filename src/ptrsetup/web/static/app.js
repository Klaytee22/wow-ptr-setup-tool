/* WoW PTR UI Setup — single-page wizard.
 *
 * The server owns all logic; this file only renders the snapshot it returns and
 * posts back selections. Every mutating call returns a fresh snapshot, so there
 * is exactly one source of truth and no client-side state to drift.
 */

const OPTION_LABELS = {
  overwrite: ["Overwrite existing PTR files", "Off = only copy files the PTR does not already have."],
  include_macros_bindings: ["Include macros and keybinds", "Copies macros-cache.txt and bindings-cache.wtf."],
  include_chat_cache: ["Include chat settings", "Copies chat-cache.txt (chat tabs and channels)."],
  allow_out_of_date: ["Allow out-of-date addons", 'Sets checkAddonVersion "0" when writing Config.wtf.'],
};

let state = null;
const selected = new Set();
let selectionInitialised = false;

/* ---------------------------------------------------------------- helpers */

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.detail || `Request failed: ${response.status}`);
  return data;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function toast(message, isError = false) {
  const node = document.getElementById("toast");
  node.textContent = message;
  node.classList.remove("hidden");
  node.style.borderColor = isError ? "var(--red)" : "var(--gold-dim)";
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => node.classList.add("hidden"), 4000);
}

function bytes(n) {
  if (!n) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let value = n;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${unit === 0 ? value : value.toFixed(1)} ${units[unit]}`;
}

/** Minimal markdown: numbered lists, **bold**, `code`. Escapes everything else. */
function markdown(text) {
  const escape = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  const inline = (s) =>
    escape(s)
      .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
      .replace(/`(.+?)`/g, "<code>$1</code>");

  const out = [];
  let list = null;
  const flush = () => {
    if (list) out.push(`<ol>${list.map((i) => `<li>${i}</li>`).join("")}</ol>`);
    list = null;
  };

  for (const raw of text.split("\n")) {
    const line = raw.trim();
    const item = line.match(/^\d+\.\s+(.*)$/);
    if (item) {
      if (!list) list = [];
      list.push(inline(item[1]));
    } else if (list && line) {
      // A wrapped continuation of the previous numbered item.
      list[list.length - 1] += ` ${inline(line)}`;
    } else {
      flush();
      if (line) out.push(`<p>${inline(line)}</p>`);
    }
  }
  flush();
  return out.join("");
}

/* ------------------------------------------------------------ rendering */

function fillSelect(node, items, value, placeholder) {
  node.innerHTML = "";
  if (placeholder) {
    const option = el("option", null, placeholder);
    option.value = "";
    node.appendChild(option);
  }
  for (const item of items) {
    const option = el("option", null, item.label);
    option.value = item.value;
    if (item.value === value) option.selected = true;
    node.appendChild(option);
  }
}

function renderInstalls() {
  const installs = state.installs;
  const selection = state.selection;
  const asOption = (i) => ({ value: i.id, label: `${i.label} — ${i.path}` });

  fillSelect(
    document.getElementById("source-install"),
    installs.filter((i) => !i.is_ptr).map(asOption),
    selection.source ? selection.source.id : "",
    "Select your live client…"
  );
  fillSelect(
    document.getElementById("target-install"),
    installs.filter((i) => i.is_ptr).map(asOption),
    selection.target ? selection.target.id : "",
    "Select your PTR client…"
  );

  const warning = document.getElementById("install-warning");
  const messages = [];
  if (!installs.length) messages.push("No World of Warcraft folders found — add yours below.");
  else if (!installs.some((i) => i.is_ptr)) messages.push("No PTR client found. Install it from the Battle.net launcher, then press Rescan.");
  if (selection.target && !selection.target.has_been_launched) {
    messages.push("The PTR client has no WTF folder yet — launch it once, quit, then rescan.");
  }
  if (selection.source && selection.target && selection.source.line !== selection.target.line) {
    messages.push("Heads up: the two clients are on different versions of the game, so settings may not carry over cleanly.");
  }
  warning.textContent = messages.join(" ");
  warning.classList.toggle("hidden", !messages.length);
}

function renderAccounts() {
  const toOptions = (names) => names.map((n) => ({ value: n, label: n }));
  fillSelect(
    document.getElementById("source-account"),
    toOptions(state.accounts.source),
    state.selection.source_account || "",
    state.accounts.source.length ? null : "No account folders found"
  );
  fillSelect(
    document.getElementById("target-account"),
    toOptions(state.accounts.target),
    state.selection.target_account || "",
    state.accounts.target.length ? null : "No account folders found"
  );
}

function renderCharacterMap() {
  const host = document.getElementById("character-map");
  host.innerHTML = "";

  const sources = state.characters.source;
  const targets = state.characters.target;
  if (!targets.length) {
    const note = el("p", "hint");
    note.textContent =
      "No characters found on the PTR client yet. Copy a character to the PTR (step 2 below), then press Rescan.";
    host.appendChild(note);
    return;
  }

  const mapped = new Map(state.selection.characters.map((p) => [p.target.id, p.source.id]));
  const table = el("table", "map");
  table.innerHTML =
    "<thead><tr><th>PTR character</th><th>Gets settings from</th></tr></thead>";
  const body = el("tbody");

  for (const target of targets) {
    const row = el("tr");
    const left = el("td");
    left.appendChild(el("div", null, target.name));
    left.appendChild(el("div", "realm", target.realm));
    row.appendChild(left);

    const right = el("td");
    const select = el("select");
    select.dataset.targetId = target.id;
    fillSelect(
      select,
      sources.map((c) => ({ value: c.id, label: `${c.name} — ${c.realm}` })),
      mapped.get(target.id) || "",
      "— skip this character —"
    );
    select.addEventListener("change", pushCharacterMap);
    right.appendChild(select);
    row.appendChild(right);
    body.appendChild(row);
  }
  table.appendChild(body);
  host.appendChild(table);
}

function renderSteps() {
  const host = document.getElementById("steps");
  host.innerHTML = "";

  for (const step of state.steps) {
    const status = step.status.state;
    const card = el("div", `step ${status}`);

    const head = el("div", "step-head");
    if (step.mode === "auto") {
      const box = el("input");
      box.type = "checkbox";
      box.checked = selected.has(step.id);
      box.disabled = status === "blocked";
      box.addEventListener("change", () => {
        if (box.checked) selected.add(step.id);
        else selected.delete(step.id);
        updateSummary();
      });
      head.appendChild(box);
    } else {
      const box = el("input");
      box.type = "checkbox";
      box.checked = status === "done";
      box.title = "Mark this manual step as done";
      box.addEventListener("change", async () => {
        state = await api(`/api/steps/${step.id}/ack`, {
          method: "POST",
          body: JSON.stringify({ done: box.checked }),
        });
        render();
      });
      head.appendChild(box);
    }

    const body = el("div", "step-body");
    const title = el("div", "step-title");
    title.appendChild(el("span", null, step.title));
    title.appendChild(el("span", `pill ${step.mode === "manual" ? "manual" : status}`,
      step.mode === "manual" ? "manual" : status));
    body.appendChild(title);
    body.appendChild(el("p", "detail", step.summary));
    if (step.status.detail) body.appendChild(el("p", "detail", step.status.detail));

    if (step.instructions) {
      const instructions = el("div", "instructions");
      instructions.innerHTML = markdown(step.instructions);
      body.appendChild(instructions);
    }

    if (step.mode === "auto" && step.action_count) {
      const details = el("details", "tucked");
      details.appendChild(el("summary", null,
        `Show the ${step.action_count} file(s) — ${bytes(step.bytes)}`));
      const list = el("div", "filelist");
      for (const action of step.preview) {
        list.appendChild(el("div", action.kind, `${action.kind.padEnd(9)} ${action.dest}${action.note ? "  · " + action.note : ""}`));
      }
      if (step.preview_truncated) list.appendChild(el("div", "skip", "… list truncated"));
      details.appendChild(list);
      body.appendChild(details);
    }

    if (step.source_note) body.appendChild(el("p", "source-note", step.source_note));

    head.appendChild(body);
    card.appendChild(head);
    host.appendChild(card);
  }
}

function renderOptions() {
  const host = document.getElementById("options");
  host.innerHTML = "";
  for (const [key, [label, hint]] of Object.entries(OPTION_LABELS)) {
    const wrap = el("label", "option");
    const box = el("input");
    box.type = "checkbox";
    box.checked = Boolean(state.selection.options[key]);
    box.addEventListener("change", async () => {
      state = await api("/api/selection", {
        method: "POST",
        body: JSON.stringify({ options: { [key]: box.checked } }),
      });
      render();
    });
    const text = el("div");
    text.appendChild(el("span", null, label));
    text.appendChild(el("p", "hint", hint));
    wrap.appendChild(box);
    wrap.appendChild(text);
    host.appendChild(wrap);
  }
}

async function renderBackups() {
  const host = document.getElementById("backup-list");
  host.innerHTML = "";
  let data;
  try {
    data = await api("/api/backups");
  } catch (error) {
    host.appendChild(el("p", "hint", error.message));
    return;
  }
  if (!data.backups.length) {
    host.appendChild(el("p", "hint", "No backups yet."));
    return;
  }
  for (const backup of data.backups) {
    const row = el("div", "backup");
    row.appendChild(el("div", null, `${backup.label} — ${backup.created} — ${backup.file_count} file(s)`));
    const button = el("button", "btn small", "Restore");
    button.addEventListener("click", async () => {
      if (!confirm(`Restore ${backup.file_count} file(s) from ${backup.id}?`)) return;
      try {
        const result = await api(`/api/backups/${backup.id}/restore`, { method: "POST" });
        state = result.state;
        render();
        toast(`Restored ${result.restored} file(s).`);
      } catch (error) {
        toast(error.message, true);
      }
    });
    row.appendChild(button);
    host.appendChild(row);
  }
}

function updateSummary() {
  const node = document.getElementById("summary");
  const steps = state.steps.filter((s) => selected.has(s.id));
  const files = steps.reduce((sum, s) => sum + s.action_count, 0);
  const size = steps.reduce((sum, s) => sum + s.bytes, 0);
  const ready = state.selection.source && state.selection.target;
  document.getElementById("apply").disabled = !ready || !files;
  document.getElementById("preview").disabled = !ready || !files;
  node.textContent = !ready
    ? "Pick a live client and a PTR client to begin."
    : `${steps.length} step(s) selected · ${files} file(s) · ${bytes(size)}`;
}

function render() {
  if (!selectionInitialised) {
    // First render: pre-tick every automated step that has work to do.
    for (const step of state.steps) {
      if (step.mode === "auto" && step.status.state !== "blocked") selected.add(step.id);
    }
    selectionInitialised = true;
  }
  renderInstalls();
  renderAccounts();
  renderCharacterMap();
  renderSteps();
  renderOptions();
  updateSummary();
}

/* -------------------------------------------------------------- actions */

async function pushSelection(payload) {
  try {
    state = await api("/api/selection", { method: "POST", body: JSON.stringify(payload) });
    render();
  } catch (error) {
    toast(error.message, true);
  }
}

function pushCharacterMap() {
  const byId = new Map();
  for (const list of [state.characters.source, state.characters.target]) {
    for (const char of list) byId.set(char.id, char);
  }
  const pairs = [];
  for (const select of document.querySelectorAll("#character-map select")) {
    if (!select.value) continue;
    const source = byId.get(select.value);
    const target = byId.get(select.dataset.targetId);
    if (source && target) {
      pairs.push({
        source: { account: source.account, realm: source.realm, name: source.name },
        target: { account: target.account, realm: target.realm, name: target.name },
      });
    }
  }
  pushSelection({ characters: pairs });
}

function showResults(results, dryRun) {
  const panel = document.getElementById("results");
  const body = document.getElementById("results-body");
  body.innerHTML = "";
  panel.classList.remove("hidden");
  body.appendChild(el("p", "hint", dryRun ? "Preview only — nothing was written." : "Applied."));
  for (const result of results) {
    const step = state.steps.find((s) => s.id === result.step_id);
    const line = el("div", "result-line");
    line.appendChild(el("span", result.ok ? "ok" : "fail", result.ok ? "✔ " : "✖ "));
    line.appendChild(el("span", null, `${step ? step.title : result.step_id} — ${result.message}`));
    body.appendChild(line);
  }
  panel.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

async function run(dryRun) {
  const ids = state.steps.filter((s) => selected.has(s.id)).map((s) => s.id);
  if (!ids.length) return toast("No steps selected.", true);
  if (!dryRun && !confirm(`Apply ${ids.length} step(s) to the PTR client?\n\nOverwritten files are backed up first.`)) return;
  try {
    const result = await api("/api/apply", {
      method: "POST",
      body: JSON.stringify({ step_ids: ids, dry_run: dryRun }),
    });
    state = result.state;
    render();
    showResults(result.results, dryRun);
    if (!dryRun) renderBackups();
  } catch (error) {
    toast(error.message, true);
  }
}

/* ------------------------------------------------------------------ wire */

document.getElementById("source-install").addEventListener("change", (e) => pushSelection({ source_id: e.target.value }));
document.getElementById("target-install").addEventListener("change", (e) => pushSelection({ target_id: e.target.value }));
document.getElementById("source-account").addEventListener("change", (e) => pushSelection({ source_account: e.target.value }));
document.getElementById("target-account").addEventListener("change", (e) => pushSelection({ target_account: e.target.value }));

document.getElementById("rescan").addEventListener("click", async () => {
  state = await api("/api/rescan", { method: "POST" });
  render();
  toast(`Found ${state.installs.length} client folder(s).`);
});

document.getElementById("add-root").addEventListener("click", async () => {
  const input = document.getElementById("root-path");
  if (!input.value.trim()) return;
  try {
    state = await api("/api/roots", { method: "POST", body: JSON.stringify({ path: input.value.trim() }) });
    input.value = "";
    render();
    toast("Folder added.");
  } catch (error) {
    toast(error.message, true);
  }
});

document.getElementById("load-backups").addEventListener("click", renderBackups);
document.getElementById("preview").addEventListener("click", () => run(true));
document.getElementById("apply").addEventListener("click", () => run(false));

(async function boot() {
  try {
    state = await api("/api/state");
    render();
    renderBackups();
  } catch (error) {
    toast(error.message, true);
  }
})();
