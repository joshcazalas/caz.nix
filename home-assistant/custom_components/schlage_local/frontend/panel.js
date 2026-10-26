/* Local HA panel. PINs never enter entity state, storage, URLs, or history.
 * Keep the shell and dialog mounted: busy feedback must not destroy focus,
 * form input, scroll position, or the last verified list.
 */
const esc = value => String(value ?? "").replace(/[&<>"']/g, c => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
})[c]);
const when = value => value ? new Date(value).toLocaleString() : "Not checked yet";
const paths = {
  settings: 'M4 7h16M4 17h16M8 4v6M16 14v6',
  menu: 'M4 6h16M4 12h16M4 18h16',
  plus: 'M12 5v14M5 12h14',
  refresh: 'M20 7v5h-5M4 17v-5h5M6 7a7 7 0 0 1 12-2l2 3M4 16l2 3a7 7 0 0 0 12-2',
  lock: 'M7 11V7a5 5 0 0 1 10 0v4M6 11h12v10H6zM12 15v2',
  eye: 'M2 12s3-7 10-7 10 7 10 7-3 7-10 7S2 12 2 12Z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
  hide: 'M3 3l18 18M9.5 5.3A12 12 0 0 1 12 5c7 0 10 7 10 7a18 18 0 0 1-3 4M6 6C3.5 8.2 2 12 2 12s3 7 10 7a12 12 0 0 0 5-1M10 10a3 3 0 0 0 4 4',
  edit: 'm15 5 4 4M4 20l4-1L20 7a2.8 2.8 0 0 0-4-4L4 15z',
  close: 'm6 6 12 12M6 18 18 6',
  info: 'M12 11v6M12 7v.1M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
  chevron: 'm9 5 7 7-7 7',
  check: 'm5 12 4 4L19 6',
  history: 'M3 4v5h5M3 9a9 9 0 1 1 0 6M12 7v5l3 2',
};
const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${paths[name]}"/></svg>`;
const styles = `
  :host{display:block;min-height:100%;background:var(--primary-background-color,#f5f7fa);color:var(--primary-text-color,#202124);font:14px var(--ha-font-family-body,var(--paper-font-body1_-_font-family,system-ui));--accent:var(--primary-color,#007fa3);--muted:var(--secondary-text-color,#62676e);--surface:var(--card-background-color,#fff);--line:var(--divider-color,#e2e5e9)}
  *{box-sizing:border-box} [hidden]{display:none!important} button,input,select{font:inherit}button{cursor:pointer}button:disabled{cursor:default;opacity:.45}svg{width:22px;height:22px;flex:none;pointer-events:none}h1,h2,h3,p{margin:0}button,input,select{color:inherit}button{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:44px;padding:0 16px;border:0;border-radius:12px;background:transparent;font-weight:600;transition:background 120ms ease}button:hover:enabled{background:var(--secondary-background-color,#edf1f5)}button:focus-visible,summary:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid var(--accent);outline-offset:3px}button.primary{background:var(--accent);color:var(--text-primary-color,#fff)}button.primary:hover:enabled{filter:brightness(.94);background:var(--accent)}button.tonal{background:color-mix(in srgb,var(--accent) 12%,var(--surface));color:var(--accent)}button.danger{color:var(--error-color,#b3261e)}button.danger.primary{background:var(--error-color,#b3261e);color:white}.icon-button{width:44px;min-width:44px;padding:0;border-radius:50%;color:var(--muted)}
  header{height:64px;display:flex;align-items:center;gap:16px;padding:0 16px;background:var(--app-header-background-color,var(--surface));color:var(--app-header-text-color,var(--primary-text-color,#202124));border-bottom:1px solid var(--line)}header .icon-button{color:inherit}header span{font-size:20px;font-weight:500}header #settings{margin-left:auto}main{max-width:840px;margin:auto;padding:36px 28px 88px}.intro{display:flex;gap:16px;align-items:center;margin-bottom:28px}.lock-icon{display:grid;place-items:center;width:52px;height:52px;border-radius:18px;background:color-mix(in srgb,var(--accent) 12%,var(--surface));color:var(--accent)}.lock-icon svg{width:26px;height:26px}h1{font-size:28px;font-weight:600;letter-spacing:-.6px;line-height:1.3}.subtitle{color:var(--muted);margin-top:5px;line-height:1.5}.subtitle span+span::before{content:' · ';padding:0 3px}select{border:1px solid var(--line);background:var(--surface);border-radius:10px;min-height:44px;padding:0 12px;margin-top:8px;max-width:100%}
  .card{background:var(--surface);border:1px solid var(--line);border-radius:20px;overflow:hidden}.card-heading{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:20px 24px 8px}h2{font-size:18px;font-weight:600}.heading-actions{display:flex;align-items:center;gap:8px}.sync{min-height:36px;display:flex;align-items:center;gap:8px;padding:0 24px 12px;color:var(--muted);font-size:13px}.sync svg{width:16px;height:16px}.search{padding:0 24px 16px}.search input{width:100%}.codes{margin:0;padding:0 12px;list-style:none}.code-row{display:flex;align-items:center;gap:14px;min-height:90px;padding:16px 12px;border-top:1px solid var(--line)}.avatar{width:42px;height:42px;border-radius:50%;display:grid;place-items:center;background:var(--secondary-background-color,#edf1f5);color:var(--muted);font-size:16px;font-weight:600;flex:none}.identity{min-width:0;flex:1}.name{font-size:16px;font-weight:600;line-height:1.4;overflow-wrap:anywhere}.pin-line{display:flex;align-items:center;gap:10px;margin-top:4px;min-height:22px}.pin{font:16px ui-monospace,SFMono-Regular,monospace;letter-spacing:2px;color:var(--muted);white-space:nowrap}.pin.revealed{color:var(--primary-text-color,#202124)}.pin-note{color:var(--muted);font-size:12px}.row-actions{display:flex;gap:2px;flex:none}.empty{padding:38px 24px 44px;text-align:center;color:var(--muted);line-height:1.6}.empty h3{color:var(--primary-text-color,#202124);font-size:17px;margin-bottom:6px}.footnote{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:13px;margin:14px 6px 24px;line-height:1.5}.footnote svg{width:16px;height:16px}.history{border-top:1px solid var(--line);margin-top:28px}summary{display:flex;align-items:center;gap:12px;cursor:pointer;min-height:64px;padding:12px 6px;list-style:none;font-weight:500}summary::-webkit-details-marker{display:none}summary svg:first-child{color:var(--muted)}summary svg:last-child{margin-left:auto;width:18px;transition:transform 120ms}.history[open] summary svg:last-child{transform:rotate(90deg)}.history-body{padding:0 6px 12px}.history-body>p{color:var(--muted);line-height:1.6;font-size:13px;margin-bottom:12px}.events{list-style:none;margin:0;padding:0}.events li{padding:12px 0;display:flex;gap:12px;align-items:start}.event-dot{width:7px;height:7px;border-radius:50%;background:var(--muted);margin:8px 2px;flex:none}.events small{display:block;color:var(--muted);margin-top:4px}.events strong{font-weight:500;overflow-wrap:anywhere}
  .notice{display:flex;align-items:start;gap:12px;border:1px solid color-mix(in srgb,var(--error-color,#b3261e) 40%,var(--line));border-radius:14px;background:var(--surface);padding:16px;margin-bottom:20px;line-height:1.5}.notice strong{display:block;margin-bottom:4px}.notice p{color:var(--muted)}.notice .icon-button{margin-left:auto;flex:none}.spinner{display:inline-block;width:16px;height:16px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:spin .9s linear infinite;flex:none}.busy-icon svg{animation:spin 1.2s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}.skeleton{display:flex;align-items:center;gap:16px;padding:24px;border-top:1px solid var(--line)}.skeleton i{height:40px;width:40px;border-radius:50%;background:var(--secondary-background-color,#edf1f5)}.skeleton span{height:14px;width:34%;border-radius:8px;background:var(--secondary-background-color,#edf1f5)}
  dialog{padding:0;border:1px solid var(--line);border-radius:24px;background:var(--surface);color:var(--primary-text-color,#202124);width:calc(100% - 40px);max-width:460px;max-height:calc(100dvh - 48px);overflow:auto;box-shadow:0 18px 64px #0004}dialog::backdrop{background:#0007}.dialog-heading{display:flex;align-items:center;gap:12px;padding:20px 20px 8px 24px}.dialog-heading h2{flex:1;font-size:22px;letter-spacing:-.3px}.dialog-body{padding:12px 24px 24px}.dialog-body>p{line-height:1.6;color:var(--muted);margin-bottom:20px}.field{display:block;margin:0 0 20px}.field>label{display:block;font-weight:500;margin-bottom:8px}input{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px;font-size:16px;min-height:50px;min-width:0;width:100%}input:focus{border-color:var(--accent)}.field small{display:block;line-height:1.5;color:var(--muted);margin-top:8px}.pin-input{position:relative}.pin-input input{padding-right:56px;font-family:ui-monospace,monospace;letter-spacing:2px}.pin-input button{position:absolute;right:4px;top:3px}.dialog-footer{display:flex;align-items:center;justify-content:flex-end;gap:8px;padding:0 24px 24px}.dialog-footer .remove-link{margin-right:auto;padding-left:0}.dialog-footer button{min-width:78px}.dialog-error{color:var(--error-color,#b3261e);line-height:1.5;margin:0 24px 20px}.dialog-progress{min-height:24px;display:flex;align-items:center;gap:10px;color:var(--muted);font-size:13px;margin:0 24px 16px}.code-details{margin-top:20px;color:var(--muted);font-size:12px;overflow-wrap:anywhere}.code-details summary{min-height:44px;padding:0}.code-details p{line-height:1.6;padding-bottom:10px}.about-copy{line-height:1.6;color:var(--muted)}.about-copy h3{font-size:15px;color:var(--primary-text-color,#202124);margin:18px 0 6px}.about-copy p{margin:0}.about-copy button{margin-top:8px}.toast{position:fixed;bottom:max(24px,env(safe-area-inset-bottom));left:50%;transform:translateX(-50%);width:max-content;max-width:calc(100% - 32px);display:flex;align-items:center;gap:12px;background:var(--primary-text-color,#202124);color:var(--primary-background-color,#fff);padding:8px 8px 8px 18px;border-radius:14px;box-shadow:0 4px 20px #0003;z-index:5;line-height:1.5}.toast .icon-button{color:inherit;flex:none}.toast>svg{width:20px}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
  @media(max-width:600px){header{height:56px;padding:0 8px}main{padding:24px 16px 88px}.intro{gap:12px;margin-bottom:24px}h1{font-size:25px}.lock-icon{width:46px;height:46px;border-radius:16px}.card-heading{padding:16px 16px 8px}.sync{padding:0 16px 12px}.codes{padding:0 6px}.code-row{padding:16px 10px;gap:10px}.avatar{width:34px;height:34px;font-size:14px}.row-actions{gap:0}.pin-note{display:none}.heading-actions{gap:0}.search{padding:0 16px 16px}dialog{width:100%;max-width:100%;max-height:90dvh;margin:auto 0 0;border-radius:24px 24px 0 0;border-bottom:0;padding-bottom:env(safe-area-inset-bottom)}.dialog-heading{padding-top:16px}.toast{bottom:max(16px,env(safe-area-inset-bottom))}}@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}`;

class SchlageCodePanel extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({mode: "open"});
    this.devices = [];
    this.snapshot = null;
    this.busy = false;
    this.stale = false;
    this.privacyEpoch = 0;
    this.hidePins = () => {
      this.privacyEpoch++;
      clearTimeout(this.revealTimer);
      this.revealed = null;
      this.updatePins();
      const input = this.$("#pin");
      if (input) input.type = "password";
      this.updateInputToggle();
    };
  }
  $(selector) { return this.shadowRoot.querySelector(selector); }
  set hass(value) {
    this._hass = value;
    if (this.isConnected && !this.started) this.start();
  }
  connectedCallback() {
    if (!this.$("main")) this.mount();
    document.addEventListener("visibilitychange", this.hidePins);
    window.addEventListener("blur", this.hidePins);
    this.update();
    if (this._hass && !this.started) this.start();
  }
  disconnectedCallback() {
    document.removeEventListener("visibilitychange", this.hidePins);
    window.removeEventListener("blur", this.hidePins);
    this.hidePins();
    clearTimeout(this.toastTimer);
    clearTimeout(this.slowTimer);
    this.closeDialog(true);
  }
  call(action, args = {}) { return this._hass.callWS({type: "schlage_local/command", action, ...args}); }

  mount() {
    this.shadowRoot.innerHTML = `<style>${styles}</style>
      <header><button id="menu" class="icon-button" aria-label="Open navigation">${icon("menu")}</button><span>Lock codes</span><button id="settings" class="icon-button" aria-label="Lock settings" title="Lock settings">${icon("settings")}</button><button id="about" class="icon-button" aria-label="About lock codes" title="About lock codes">${icon("info")}</button></header>
      <main>
        <div class="intro"><div class="lock-icon">${icon("lock")}</div><div><h1>Access codes</h1><div class="subtitle"><span id="lock-name">Your lock</span><span>Local control</span></div><label id="lock-picker" hidden><span class="sr-only">Lock</span><select id="lock"></select></label></div></div>
        <div id="error" class="notice" role="alert" hidden><div><strong>Couldn’t finish that request</strong><p id="error-message"></p><p id="stale-message" hidden>Your previous list is still shown. Refresh before making changes.</p></div></div>
        <section class="card" aria-labelledby="codes-heading"><div class="card-heading"><h2 id="codes-heading">Codes</h2><div class="heading-actions"><button id="refresh" class="icon-button" aria-label="Refresh from lock" title="Refresh from lock">${icon("refresh")}</button><button id="add" class="primary">${icon("plus")}Add code</button></div></div>
          <div class="sync" role="status" aria-live="polite"><span id="sync-icon">${icon("lock")}</span><span id="sync-text">Connecting to your lock…</span></div>
          <label id="search-label" class="search" hidden><span class="sr-only">Search codes</span><input id="search" type="search" placeholder="Search by name" autocomplete="off"></label>
          <ul id="codes" class="codes" aria-label="Keypad codes"></ul>
          <div id="placeholder" class="skeleton" aria-hidden="true"><i></i><span></span></div>
          <div id="empty" class="empty" hidden></div>
        </section>
        <p class="footnote">${icon("lock")}Codes keep working when Home Assistant is offline.</p>
        <details id="history" class="history"><summary>${icon("history")}Code activity${icon("chevron")}</summary><div class="history-body"><p>Code changes made here. Door entries and per-code usage aren’t available.</p><ul id="events" class="events"></ul></div></details>
      </main>
      <div id="toast" class="toast" role="status" hidden>${icon("check")}<span></span><button id="dismiss" class="icon-button" aria-label="Dismiss message">${icon("close")}</button></div>
      <dialog id="dialog" aria-labelledby="dialog-title"></dialog>`;
    this.$("#menu").onclick = () => this.dispatchEvent(new CustomEvent("hass-toggle-menu", {bubbles: true, composed: true}));
    this.$("#refresh").onclick = () => this.refresh();
    this.$("#add").onclick = () => this.openDialog("add");
    this.$("#settings").onclick = () => this.openDialog("settings");
    this.$("#about").onclick = () => this.openDialog("about");
    this.$("#dismiss").onclick = () => { this.$("#toast").hidden = true; };
    this.$("#search").oninput = () => this.filterRows();
    this.$("#lock").onchange = event => {
      this.hidePins();
      this.lockId = event.target.value;
      this.snapshot = null;
      this.$("#search").value = "";
      this.renderList();
      this.refresh();
    };
    this.$("#codes").onclick = event => {
      const button = event.target.closest("button[data-code]");
      if (!button || this.busy || this.stale) return;
      if (button.dataset.action === "reveal") this.reveal(button.dataset.code);
      else this.openDialog("edit", button.dataset.code);
    };
    this.$("#dialog").addEventListener("cancel", event => { event.preventDefault(); this.closeDialog(); });
    this.update();
  }

  async run(label, operation, {success = "", origin = "refresh", affectsCodes = true} = {}) {
    if (this.busy) return;
    this.busy = true;
    this.origin = origin;
    this.progress = label;
    this.error = "";
    this.hidePins();
    this.$("#toast").hidden = true;
    this.update();
    this.slowTimer = setTimeout(() => {
      this.progress = `${label} Still waiting for the lock; please leave this open.`;
      this.update();
    }, 10000);
    try {
      await operation();
      if (success && this.isConnected) this.notify(success);
    } catch (err) {
      this.error = err.message || "The connection failed. Refresh to check the lock.";
      if (affectsCodes) this.stale = true;
    } finally {
      clearTimeout(this.slowTimer);
      this.busy = false;
      this.origin = null;
      this.progress = "";
      if (this.isConnected) {
        this.update();
        if (this.pendingFocus) { this.pendingFocus = false; this.restoreFocus(); }
      }
    }
  }
  async start() {
    this.started = true;
    await this.run("Reading codes…", async () => {
      const result = await this.call("discover");
      this.devices = result.locks;
      this.$("#lock").innerHTML = this.devices.map(d => `<option value="${esc(d.id)}">${esc(d.name)}</option>`).join("");
      if (this.devices.length) {
        this.lockId = this.devices[0].id;
        this.applySnapshot(await this.call("list", {lock_id: this.lockId}));
      } else this.renderList();
    });
  }
  refresh() {
    if (this.busy) return;
    if (!this.lockId) return this.start();
    return this.run("Refreshing codes…", async () => {
      this.applySnapshot(await this.call("list", {lock_id: this.lockId}));
    });
  }
  applySnapshot(snapshot) {
    this.snapshot = snapshot;
    this.stale = false;
    this.renderList();
  }
  renderList() {
    const codes = this.snapshot?.codes || [];
    this.$("#codes").innerHTML = codes.map(c => `<li class="code-row" data-row="${esc(c.id)}">
      <div class="avatar" aria-hidden="true">${esc((c.name || "?").trim().slice(0, 1).toUpperCase())}</div>
      <div class="identity"><div class="name">${esc(c.name || "Unnamed code")}</div><div class="pin-line"><span class="pin" data-pin="${esc(c.id)}" aria-label="Hidden PIN">••••••</span><span class="pin-note" data-note="${esc(c.id)}"></span></div></div>
      <div class="row-actions"><button class="icon-button" data-code="${esc(c.id)}" data-action="reveal" title="Show PIN" aria-label="Show PIN for ${esc(c.name || "unnamed code")}">${icon("eye")}</button><button class="icon-button" data-code="${esc(c.id)}" data-action="edit" title="Edit code" aria-label="Edit ${esc(c.name || "unnamed code")}">${icon("edit")}</button></div></li>`).join("");
    this.$("#search-label").hidden = codes.length < 8 && !this.$("#search").value;
    const actions = {added: "Code added", removed: "Code removed", renamed: "Name changed", add_unverified: "Add needs checking", remove_unverified: "Removal needs checking", auto_lock_changed: "Auto-lock changed"};
    this.$("#events").innerHTML = (this.snapshot?.events || []).map(e => `<li><span class="event-dot"></span><div><strong>${esc(actions[e.action] || "Code change")} · ${esc(e.name || "Unnamed code")}</strong><small>${esc(when(e.time))}</small></div></li>`).join("") || '<li>No code changes recorded yet.</li>';
    this.filterRows();
  }
  filterRows() {
    const query = this.$("#search").value.trim().toLocaleLowerCase();
    let visible = 0;
    this.shadowRoot.querySelectorAll("[data-row]").forEach(row => {
      row.hidden = !row.querySelector(".name").textContent.toLocaleLowerCase().includes(query);
      if (!row.hidden) visible++;
    });
    const empty = this.$("#empty");
    empty.hidden = visible > 0 || (!this.snapshot && this.busy);
    if (!this.snapshot) empty.innerHTML = this.devices.length ? 'Refresh to read the codes on your lock.' : 'No supported lock is loaded. Check HomeKit Device, then refresh.';
    else if (query && !visible) empty.innerHTML = '<h3>No matching codes</h3>Try another name.';
    else empty.innerHTML = '<h3>No codes yet</h3>Add a code for yourself or someone you trust.';
  }
  updatePins() {
    this.shadowRoot.querySelectorAll("[data-pin]").forEach(el => {
      const shown = this.revealed?.id === el.dataset.pin;
      el.textContent = shown ? this.revealed.pin : "••••••";
      el.classList.toggle("revealed", shown);
      if (shown) el.removeAttribute("aria-label"); else el.setAttribute("aria-label", "Hidden PIN");
    });
    this.shadowRoot.querySelectorAll('[data-action="reveal"]').forEach(button => {
      const shown = this.revealed?.id === button.dataset.code;
      const code = this.snapshot?.codes.find(c => c.id === button.dataset.code);
      button.innerHTML = icon(shown ? "hide" : "eye");
      button.setAttribute("aria-label", `${shown ? "Hide" : "Show"} PIN for ${code?.name || "unnamed code"}`);
      button.title = shown ? "Hide PIN" : "Show PIN";
    });
    this.shadowRoot.querySelectorAll("[data-note]").forEach(el => { el.textContent = this.revealed?.id === el.dataset.note ? "Hides in 20s" : ""; });
  }
  update() {
    if (!this.$("main")) return;
    const ready = !!this.snapshot && !this.stale && !this.busy;
    const capacity = this.snapshot?.capabilities.capacity || 0;
    const count = this.snapshot?.codes.length || 0;
    this.$("#codes-heading").textContent = this.snapshot ? `${count} ${count === 1 ? "code" : "codes"}` : "Codes";
    this.$("#lock-name").textContent = this.devices.find(d => d.id === this.lockId)?.name || "Your lock";
    this.$("#lock-picker").hidden = this.devices.length < 2;
    this.$("#lock").disabled = this.busy;
    this.$("#add").disabled = !ready || count >= capacity;
    this.$("#add").title = count >= capacity && this.snapshot ? "This lock is at its code limit" : "Add code";
    this.$("#refresh").disabled = this.busy;
    this.$("#refresh").classList.toggle("busy-icon", this.busy && this.origin === "refresh");
    this.$("#about").disabled = this.busy;
    this.$("#settings").disabled = this.busy || !this.lockId;
    this.$("#codes").setAttribute("aria-busy", String(this.busy));
    this.$("#sync-text").textContent = this.busy ? this.progress : this.stale ? "Refresh needed" : this.snapshot ? `Checked ${new Date(this.snapshot.read_at).toLocaleTimeString([], {hour: "numeric", minute: "2-digit"})} · ${count} of ${capacity} codes used` : "Not connected";
    this.$("#sync-text").title = this.snapshot ? when(this.snapshot.read_at) : "";
    this.$("#sync-icon").innerHTML = this.busy ? '<span class="spinner" aria-hidden="true"></span>' : icon(this.stale ? "info" : "lock");
    this.$("#placeholder").hidden = !!this.snapshot || !this.busy;
    this.$("#history").hidden = !this.snapshot;
    this.shadowRoot.querySelectorAll("[data-code]").forEach(button => {
      const code = this.snapshot?.codes.find(c => c.id === button.dataset.code);
      button.disabled = !ready || (button.dataset.action === "reveal" && !code?.can_reveal);
      const loading = this.busy && this.origin === `reveal:${button.dataset.code}` && button.dataset.action === "reveal";
      if (loading) button.innerHTML = '<span class="spinner" aria-hidden="true"></span>';
      else if (button.dataset.action === "reveal") button.innerHTML = icon(this.revealed?.id === button.dataset.code ? "hide" : "eye");
    });
    this.$("#error").hidden = !this.error || this.$("#dialog").open;
    this.$("#error-message").textContent = this.error || "";
    this.$("#stale-message").hidden = !this.stale || !this.snapshot;
    if (this.$("#dialog").open) {
      this.$("#dialog-error").textContent = this.error || "";
      this.$("#dialog-error").hidden = !this.error;
      const progress = this.$("#dialog-progress");
      progress.hidden = !this.busy;
      progress.querySelector("span:last-child").textContent = this.progress || "";
      this.$("#dialog").querySelectorAll("button,input,select").forEach(el => { el.disabled = this.busy; });
      const submit = this.$("#submit");
      if (submit) submit.disabled = this.dialogMode === "settings" ? this.busy || !this.autoLock?.writable : !ready;
      if (this.$("#remove")) this.$("#remove").disabled = !ready;
      if (this.$("#auto-lock")) this.$("#auto-lock").disabled = this.busy || !this.autoLock?.writable;
      if (this.$("#logs")) this.$("#logs").disabled = this.busy || !this.lockId;
      this.$("#cancel").textContent = this.stale ? "Close and refresh" : this.dialogMode === "about" ? "Done" : "Cancel";
    }
    this.filterRows();
  }
  notify(text) {
    clearTimeout(this.toastTimer);
    this.$("#toast span").textContent = text;
    this.$("#toast").hidden = false;
    this.toastTimer = setTimeout(() => { this.$("#toast").hidden = true; }, 8000);
  }

  openDialog(mode, codeId, preserveFocus = false) {
    if (this.busy || (!["about", "settings"].includes(mode) && (!this.snapshot || this.stale))) return;
    this.hidePins();
    this.error = "";
    const dialog = this.$("#dialog");
    if (!preserveFocus) {
      this.returnFocus = this.shadowRoot.activeElement;
      this.returnCode = this.returnFocus?.dataset.code;
      this.returnAction = this.returnFocus?.dataset.action;
    }
    this.dialogMode = mode;
    this.dialogCode = codeId;
    const code = this.snapshot?.codes.find(c => c.id === codeId);
    if ((mode === "edit" || mode === "remove") && !code) return;
    const title = {add: "Add code", edit: "Edit code", remove: "Remove code?", about: "About lock codes", settings: "Lock settings"}[mode];
    const caps = this.snapshot?.capabilities;
    const content = mode === "add" || mode === "edit" ? `<div class="field"><label for="name">Name</label><input aria-describedby="name-hint" id="name" maxlength="64" required autocomplete="off" value="${esc(code?.name || "")}" placeholder="e.g. Person or Guest"><small id="name-hint">Only saved in Home Assistant.</small></div>
      ${mode === "add" ? `<div class="field"><label for="pin">PIN</label><div class="pin-input"><input id="pin" type="password" inputmode="numeric" pattern="[0-9]{${caps.minimum},${caps.maximum}}" minlength="${caps.minimum}" maxlength="${caps.maximum}" required autocomplete="new-password" aria-describedby="pin-hint"><button id="toggle-pin" class="icon-button" type="button" aria-label="Show entered PIN">${icon("eye")}</button></div><small id="pin-hint">${caps.minimum}–${caps.maximum} digits. Test it with the door open after adding.</small></div>` : `<p class="subtitle">Renaming keeps the same PIN and keypad access.</p><details class="code-details"><summary>Code details</summary><p>ID ${esc(code.id)}<br>Last used: unavailable.<br>Restriction flags are not interpreted.</p></details>`}` : mode === "settings" ? `<p>Auto-lock runs on the lock itself, even when Home Assistant is offline.</p><div class="field"><label for="auto-lock">Auto-lock after</label><select id="auto-lock" aria-describedby="auto-lock-hint" disabled><option>Reading setting…</option></select><small id="auto-lock-hint">Time since unlocking. The bolt can extend while the door is open.</small></div><button id="read-settings" type="button" class="tonal">Read setting again</button>` : mode === "remove" ? `<p><strong>${esc(code.name || "This code")}</strong> will lose keypad access. You can add a new code later.</p>` : `<div class="about-copy"><p>Codes are managed locally through your existing HomeKit connection.</p><h3>PIN privacy</h3><p>PINs stay hidden until you reveal them and hide again after 20 seconds or when you leave this window. They aren’t saved in this panel’s storage or history.</p><h3>Activity</h3><p>Code activity records changes made here. Per-code door entries aren’t available.</p><details class="code-details"><summary>Connection diagnostics</summary><p>Check whether the lock returns activity data. This does not enable usage history.</p><button type="button" id="logs" class="tonal">Check activity support</button><p id="log-result"></p></details></div>`;
    dialog.innerHTML = `<form id="code-form"><div class="dialog-heading"><h2 id="dialog-title">${title}</h2><button id="close" class="icon-button" type="button" aria-label="Close dialog">${icon("close")}</button></div><div class="dialog-body">${content}</div><p id="dialog-error" class="dialog-error" role="alert" hidden></p><div id="dialog-progress" class="dialog-progress" role="status" hidden><span class="spinner" aria-hidden="true"></span><span></span></div><div class="dialog-footer">${mode === "edit" ? '<button id="remove" class="danger remove-link" type="button">Remove code</button>' : ""}<button id="cancel" type="button">${mode === "about" ? "Done" : "Cancel"}</button>${mode !== "about" ? `<button id="submit" class="primary ${mode === "remove" ? "danger" : ""}" type="submit">${mode === "add" ? "Add code" : mode === "remove" ? "Remove code" : "Save"}</button>` : ""}</div></form>`;
    this.$("#close").onclick = () => this.closeDialog();
    this.$("#cancel").onclick = () => { const refresh = this.stale; this.closeDialog(); if (refresh) this.refresh(); };
    if (this.$("#remove")) this.$("#remove").onclick = () => this.openDialog("remove", codeId, true);
    this.$("#code-form").onsubmit = event => { event.preventDefault(); this.submitDialog(); };
    if (this.$("#toggle-pin")) this.$("#toggle-pin").onclick = () => {
      const input = this.$("#pin");
      input.type = input.type === "password" ? "text" : "password";
      this.updateInputToggle();
    };
    if (mode === "settings") {
      this.autoLock = null;
      this.$("#read-settings").onclick = () => this.readSettings();
    }
    if (this.$("#logs")) this.$("#logs").onclick = () => this.run("Checking activity support…", async () => {
      const {logs} = await this.call("logs", {lock_id: this.lockId});
      if (this.$("#log-result")) this.$("#log-result").textContent = logs.bytes ? "Activity data was returned, but its format is not supported yet." : "No activity data was returned.";
    }, {origin: "dialog", affectsCodes: false});
    if (!dialog.open) dialog.showModal();
    this.update();
    (this.$("#name") || this.$("#cancel")).focus();
    if (mode === "edit") this.$("#name").select();
    if (mode === "settings") this.readSettings();
  }
  updateInputToggle() {
    const button = this.$("#toggle-pin");
    if (!button) return;
    const shown = this.$("#pin").type === "text";
    button.setAttribute("aria-label", `${shown ? "Hide" : "Show"} entered PIN`);
    button.innerHTML = icon(shown ? "hide" : "eye");
  }
  closeDialog(force = false) {
    if (this.busy && !force) return;
    const dialog = this.$("#dialog");
    if (!dialog?.open) return;
    this.hidePins();
    const input = this.$("#pin");
    if (input) input.value = "";
    dialog.close();
    dialog.innerHTML = "";
    if (this.busy) this.pendingFocus = true; else this.restoreFocus();
    if (this.isConnected) this.update();
  }
  restoreFocus() {
    const replacement = [...this.shadowRoot.querySelectorAll("[data-code]")].find(el => el.dataset.code === this.returnCode && el.dataset.action === this.returnAction);
    const target = this.returnFocus?.isConnected ? this.returnFocus : replacement || this.$("#add");
    if (target?.disabled) this.$("#refresh")?.focus(); else target?.focus();
  }
  submitDialog() {
    if (this.busy) return;
    if (this.dialogMode === "settings") return this.saveSettings();
    if (this.stale) return;
    const mode = this.dialogMode;
    const nameInput = this.$("#name");
    if (nameInput && !nameInput.value.trim()) {
      nameInput.setCustomValidity("Enter a name for this code.");
      nameInput.reportValidity();
      nameInput.oninput = () => nameInput.setCustomValidity("");
      return;
    }
    const args = {lock_id: this.lockId, revision: this.snapshot.revision};
    if (mode === "edit" || mode === "remove") args.code_id = this.dialogCode;
    if (nameInput) args.name = nameInput.value.trim();
    if (mode === "add") { args.pin = this.$("#pin").value; this.$("#pin").value = ""; }
    const action = {add: "add", edit: "rename", remove: "remove"}[mode];
    if (!action) return;
    const label = {add: "Adding code and checking the lock…", edit: "Saving name…", remove: "Removing code and checking the lock…"}[mode];
    const success = {add: "Code added. Test it with the door open.", edit: "Name saved.", remove: "Code removed from the lock."}[mode];
    this.run(label, async () => {
      this.applySnapshot(await this.call(action, args));
      this.closeDialog(true);
    }, {success, origin: "dialog"});
  }
  readSettings() {
    return this.run("Reading auto-lock setting…", async () => {
      this.autoLock = null;
      const result = await this.call("settings", {lock_id: this.lockId});
      this.autoLock = result.auto_lock;
      this.renderAutoLock();
    }, {origin: "dialog", affectsCodes: false});
  }
  renderAutoLock() {
    const select = this.$("#auto-lock");
    if (!select || !this.autoLock) return;
    const {seconds, minimum, maximum, step, valid_values: valid} = this.autoLock;
    const values = [...new Set([0, 30, 60, 120, 180, 240, 300, seconds])]
      .filter(value => value >= minimum && value <= maximum && (value - minimum) % (step || 1) === 0 && (!valid?.length || valid.includes(value)))
      .sort((a, b) => a - b);
    select.innerHTML = values.map(value => `<option value="${value}">${value === 0 ? "Off" : value % 60 ? `${value} seconds` : `${value / 60} ${value === 60 ? "minute" : "minutes"}`}</option>`).join("");
    select.value = String(seconds);
  }
  saveSettings() {
    if (this.busy || !this.autoLock?.writable) return;
    const seconds = Number(this.$("#auto-lock").value);
    const expected = this.autoLock.seconds;
    return this.run("Saving and checking auto-lock…", async () => {
      this.autoLock = null;
      const result = await this.call("set_auto_lock", {lock_id: this.lockId, seconds, expected});
      this.autoLock = result.auto_lock;
      this.closeDialog(true);
    }, {origin: "dialog", affectsCodes: false, success: seconds ? "Auto-lock updated on the lock." : "Auto-lock turned off."});
  }
  reveal(codeId) {
    if (this.busy || this.stale) return;
    if (this.revealed?.id === codeId) { this.hidePins(); return; }
    this.run("Reading PIN…", async () => {
      const epoch = this.privacyEpoch;
      const result = await this.call("reveal", {lock_id: this.lockId, revision: this.snapshot.revision, code_id: codeId});
      // A late reply must not reveal a PIN after the user leaves the window.
      if (!this.isConnected || document.hidden || epoch !== this.privacyEpoch) return;
      this.revealed = {id: codeId, pin: result.pin};
      this.updatePins();
      this.revealTimer = setTimeout(this.hidePins, 20000);
    }, {origin: `reveal:${codeId}`});
  }
}
customElements.define("schlage-code-panel", SchlageCodePanel);
