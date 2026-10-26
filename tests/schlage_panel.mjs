// Mocked HA only. No connection to a server or physical lock, even for mutations.
import assert from "node:assert/strict";
import {createRequire} from "node:module";
import {fileURLToPath} from "node:url";
const {chromium} = createRequire(import.meta.url)("playwright");
const browser = await chromium.launch({headless: true, args: ["--no-sandbox"]});
const panelPath = fileURLToPath(new URL("../home-assistant/custom_components/schlage_local/frontend/panel.js", import.meta.url));
const themes = {
  dark: '--primary-text-color:#e6e8ed;--secondary-text-color:#abb6c8;--primary-background-color:#111722;--card-background-color:#1b2433;--divider-color:#354157;--primary-color:#3598dc;--text-primary-color:#fff;--secondary-background-color:#27354a;--app-header-background-color:#1b2433;--app-header-text-color:#e6e8ed',
  light: '--primary-text-color:#202124;--secondary-text-color:#62676e;--primary-background-color:#f5f7fa;--card-background-color:#fff;--divider-color:#e2e5e9;--primary-color:#007fa3;--text-primary-color:#fff;--secondary-background-color:#edf1f5;--app-header-background-color:#fff;--app-header-text-color:#202124',
};
const errors = [];
async function fixture(width = 390, theme = "light") {
  const page = await browser.newPage({viewport: {width, height: 844}});
  page.on("pageerror", error => errors.push(error.message));
  page.on("dialog", () => {throw new Error("Native browser prompt/confirm is not expected");});
  await page.clock.install();
  await page.setContent(`<style>body{margin:0;${themes[theme]}}</style><schlage-code-panel></schlage-code-panel>`);
  await page.addScriptTag({path: panelPath});
  await page.evaluate(() => {
    window.requests = [];
    window.fail = null;
    window.defer = null;
    window.autoLock = 0;
    window.sample = {
      lock_id: "lock", revision: "r1", read_at: "2026-01-01T12:00:00Z",
      capabilities: {minimum: 4, maximum: 8, capacity: 100}, events: [],
      codes: [{id: "00ff", name: "Example user", can_reveal: true, flags: 0, last_used: null}],
    };
    window.component = document.querySelector("schlage-code-panel");
    component.hass = {
      callWS: async message => {
        window.requests.push(message);
        if (message.action === window.defer) await new Promise(resolve => {window.release = resolve;});
        if (message.action === window.fail) throw new Error("Connection unavailable. Refresh to check the lock.");
        if (message.action === "discover") return {locks: [{id: "lock", name: "Example lock"}]};
        if (message.action === "reveal") return {pin: "123456"};
        if (message.action === "set_auto_lock") window.autoLock = message.seconds;
        if (["settings", "set_auto_lock"].includes(message.action)) return {auto_lock: {seconds: window.autoLock, minimum: 0, maximum: 300, step: 1, writable: true}};
        if (message.action === "logs") return {logs: {bytes: 0}};
        if (message.action === "add") window.sample.codes.push({id: "02", name: message.name, can_reveal: true, flags: 0});
        if (message.action === "remove") window.sample.codes = window.sample.codes.filter(c => c.id !== message.code_id);
        if (message.action === "rename") window.sample.codes.find(c => c.id === message.code_id).name = message.name;
        if (["add", "remove", "rename"].includes(message.action)) {
          window.sample.revision += "x";
          window.sample.events.unshift({action: {add: "added", remove: "removed", rename: "renamed"}[message.action], name: message.name || "Guest", time: "2026-01-01T12:00:00Z"});
        }
        return structuredClone(window.sample);
      },
    };
  });
  await page.getByRole("heading", {name: "1 code", exact: true}).waitFor();
  return page;
}
const button = (page, name) => page.getByRole("button", {name, exact: true});
const waitIdle = page => page.waitForFunction(() => !component.busy);
try {
  const page = await fixture();
  assert.deepEqual(await page.evaluate(() => requests.map(r => r.action)), ["discover", "list"]);
  assert.equal(await page.getByRole("textbox", {name: "Name", exact: true}).count(), 0);
  assert.equal(await page.getByText("123456", {exact: true}).count(), 0);
  assert.equal(await page.locator("#lock-picker").isVisible(), false);
  assert.equal(await page.getByText("Last used: unavailable.").count(), 0);
  // Revealing is a small update; existing row and focus survive. Hide is immediate/local.
  await page.evaluate(() => {window.rowBefore = component.shadowRoot.querySelector("[data-row]");});
  await button(page, "Show PIN for Example user").click();
  await page.getByText("123456", {exact: true}).waitFor();
  assert.equal(await page.evaluate(() => rowBefore === component.shadowRoot.querySelector("[data-row]")), true);
  await button(page, "Hide PIN for Example user").click();
  assert.equal(await page.getByText("123456", {exact: true}).count(), 0);
  assert.equal(await page.evaluate(() => requests.filter(r => r.action === "reveal").length), 1);
  await button(page, "Show PIN for Example user").click();
  await page.getByText("123456", {exact: true}).waitFor();
  await page.clock.fastForward(21000);
  assert.equal(await page.getByText("123456", {exact: true}).count(), 0);
  // A delayed reveal cannot display a PIN after blur, even if focus returns first.
  await page.evaluate(() => {window.defer = "reveal";});
  await button(page, "Show PIN for Example user").click();
  await page.waitForFunction(() => !!window.release);
  await page.evaluate(() => {window.dispatchEvent(new Event("blur")); window.release(); window.defer = null;});
  await waitIdle(page);
  assert.equal(await page.getByText("123456", {exact: true}).count(), 0);
  // Edit uses an accessible modal. Escape cancels without writing and restores focus.
  await button(page, "Edit Example user").click();
  const dialog = page.getByRole("dialog");
  assert.equal(await dialog.getByLabel("Name", {exact: true}).inputValue(), "Example user");
  await page.keyboard.press("Escape");
  assert.equal(await dialog.count(), 0);
  assert.equal(await button(page, "Edit Example user").evaluate(el => el.getRootNode().activeElement === el), true);
  await button(page, "Edit Example user").click();
  await dialog.getByLabel("Name", {exact: true}).fill("Example user's code");
  await button(page, "Save").click();
  await button(page, "Edit Example user's code").waitFor();
  assert.equal(await page.evaluate(() => requests.filter(r => r.action === "rename").length), 1);
  assert.equal(await button(page, "Edit Example user's code").evaluate(el => el.getRootNode().activeElement === el), true);
  // Add keeps its form stable while waiting, clears the PIN, and prevents duplicates.
  await button(page, "Add code").click();
  await dialog.getByLabel("Name", {exact: true}).fill('<img src=x onerror="alert(1)">');
  await dialog.getByLabel("PIN", {exact: true}).fill("456789");
  await button(page, "Show entered PIN").click();
  assert.equal(await dialog.getByLabel("PIN", {exact: true}).getAttribute("type"), "text");
  await page.evaluate(() => window.dispatchEvent(new Event("blur")));
  assert.equal(await dialog.getByLabel("PIN", {exact: true}).getAttribute("type"), "password");
  await page.evaluate(() => {window.defer = "add"; window.formBefore = component.shadowRoot.querySelector("#code-form");});
  await dialog.getByRole("button", {name: "Add code", exact: true}).click();
  await page.waitForFunction(() => component.busy);
  assert.equal(await dialog.getByLabel("PIN", {exact: true}).inputValue(), "");
  assert.equal(await dialog.getByLabel("Name", {exact: true}).inputValue(), '<img src=x onerror="alert(1)">');
  assert.equal(await page.evaluate(() => formBefore === component.shadowRoot.querySelector("#code-form")), true);
  assert.equal(await button(page, "Cancel").isDisabled(), true);
  await page.keyboard.press("Escape");
  assert.equal(await dialog.count(), 1);
  await page.evaluate(() => component.submitDialog());
  assert.equal(await page.evaluate(() => requests.filter(r => r.action === "add").length), 1);
  await page.clock.fastForward(11000);
  await dialog.getByText(/Still waiting for the lock/).waitFor();
  await page.evaluate(() => {window.defer = null; window.release();});
  await page.getByRole("heading", {name: "2 codes", exact: true}).waitFor();
  await waitIdle(page);
  assert.equal(await page.locator("schlage-code-panel img").count(), 0);
  assert.equal(await page.getByText("456789", {exact: true}).count(), 0);
  assert.equal(await button(page, "Add code").evaluate(el => el.getRootNode().activeElement === el), true);
  // Remove has a named confirmation, safe initial focus, and cancellable intent.
  await page.locator('[data-action="edit"]').last().click();
  await button(page, "Remove code").click();
  await page.getByRole("heading", {name: "Remove code?", exact: true}).waitFor();
  assert.equal(await button(page, "Cancel").evaluate(el => el.getRootNode().activeElement === el), true);
  await button(page, "Cancel").click();
  assert.equal(await page.evaluate(() => requests.filter(r => r.action === "remove").length), 0);
  await page.locator('[data-action="edit"]').last().click();
  await button(page, "Remove code").click();
  await button(page, "Remove code").click();
  await page.getByRole("heading", {name: "1 code", exact: true}).waitFor();
  assert.equal(await page.evaluate(() => requests.filter(r => r.action === "remove").length), 1);
  // Failed refresh preserves rows and disables all changes until successful read.
  await page.evaluate(() => {window.fail = "list";});
  await button(page, "Refresh from lock").click();
  await page.getByRole("alert").waitFor();
  assert.equal(await button(page, "Edit Example user's code").isDisabled(), true);
  assert.equal(await button(page, "Add code").isDisabled(), true);
  assert.equal(await button(page, "Refresh from lock").isEnabled(), true);
  await page.getByText(/Your previous list is still shown/).waitFor();
  await page.evaluate(() => {window.fail = null;});
  await button(page, "Refresh from lock").click();
  await waitIdle(page);
  assert.equal(await button(page, "Edit Example user's code").isEnabled(), true);
  // Uncertain add is not retried. Keep the name, clear the PIN, offer refresh.
  await button(page, "Add code").click();
  await dialog.getByLabel("Name", {exact: true}).fill("Guest");
  await dialog.getByLabel("PIN", {exact: true}).fill("876543");
  await page.evaluate(() => {window.fail = "add";});
  await dialog.getByRole("button", {name: "Add code", exact: true}).click();
  await dialog.getByRole("alert").waitFor();
  assert.equal(await dialog.getByLabel("Name", {exact: true}).inputValue(), "Guest");
  assert.equal(await dialog.getByLabel("PIN", {exact: true}).inputValue(), "");
  assert.equal(await dialog.getByRole("button", {name: "Add code", exact: true}).isDisabled(), true);
  await page.evaluate(() => {window.fail = null;});
  await button(page, "Close and refresh").click();
  await waitIdle(page);
  assert.equal(await page.evaluate(() => requests.filter(r => r.action === "add").length), 2);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= 390));
  // Reattaching after a pending request completed offscreen restores controls.
  await page.evaluate(() => {window.defer = "list";});
  await button(page, "Refresh from lock").click();
  await page.waitForFunction(() => component.busy);
  await page.evaluate(() => {component.remove(); window.defer = null; window.release();});
  await waitIdle(page);
  await page.evaluate(() => document.body.append(component));
  assert.equal(await button(page, "Add code").isEnabled(), true);
  assert.equal(await page.getByText("123456", {exact: true}).count(), 0);
  // Auto-lock is read explicitly and saved with the observed value as a guard.
  const writesBeforeSettings = await page.evaluate(() => requests.filter(r => r.action === "set_auto_lock").length);
  await button(page, "Lock settings").click();
  await waitIdle(page);
  assert.equal(await dialog.getByLabel("Auto-lock after", {exact: true}).inputValue(), "0");
  assert.equal(await page.evaluate(() => requests.filter(r => r.action === "set_auto_lock").length), writesBeforeSettings);
  await dialog.getByLabel("Auto-lock after", {exact: true}).selectOption("300");
  await button(page, "Save").click();
  await waitIdle(page);
  assert.equal(await dialog.count(), 0);
  assert.deepEqual(await page.evaluate(() => {
    const r = requests.findLast(r => r.action === "set_auto_lock"); return {seconds:r.seconds, expected:r.expected};
  }), {seconds:300, expected:0});
  await button(page, "Lock settings").click();
  await waitIdle(page);
  await dialog.getByLabel("Auto-lock after", {exact: true}).selectOption("0");
  await page.evaluate(() => {window.fail = "set_auto_lock";});
  await button(page, "Save").click();
  await dialog.getByRole("alert").waitFor();
  assert.equal(await button(page, "Save").isDisabled(), true);
  await page.evaluate(() => {window.fail = null;});
  await button(page, "Read setting again").click();
  await waitIdle(page);
  assert.equal(await dialog.getByLabel("Auto-lock after", {exact: true}).inputValue(), "300");
  await button(page, "Cancel").click();
  // Search is local; empty results are distinct from an empty lock.
  await page.evaluate(() => {
    sample.codes = Array.from({length: 10}, (_, i) => ({id: String(i), name: `Guest ${i}`, can_reveal: true, flags: 0}));
  });
  await button(page, "Refresh from lock").click();
  await waitIdle(page);
  const callsBeforeSearch = await page.evaluate(() => requests.length);
  await page.getByRole("searchbox", {name: "Search codes"}).fill("Guest 9");
  assert.equal(await page.locator("[data-row]:visible").count(), 1);
  await page.getByRole("searchbox", {name: "Search codes"}).fill("nobody");
  await page.getByText("No matching codes", {exact: true}).waitFor();
  assert.equal(await page.evaluate(() => requests.length), callsBeforeSearch);
  // Synthetic previews, both themes, narrow screens, and reduced motion.
  for (const [width, theme] of [[390, "light"], [390, "dark"], [1100, "light"], [320, "light"]]) {
    const preview = await fixture(width, theme);
    await preview.evaluate(() => {
      sample.codes.push({id: "a1", name: "Example guest", can_reveal: true, flags: 0}, {id: "a2", name: "Example member", can_reveal: true, flags: 0});
      component.applySnapshot(structuredClone(sample)); component.update();
    });
    assert.ok(await preview.evaluate(w => document.documentElement.scrollWidth <= w, width));
    await preview.screenshot({path: `/tmp/schlage-redesign-${theme}-${width}.png`, fullPage: true});
    await button(preview, "Add code").click();
    assert.ok(await preview.getByRole("dialog").evaluate((el, w) => el.getBoundingClientRect().width <= w, width));
    await preview.screenshot({path: `/tmp/schlage-redesign-add-${theme}-${width}.png`, fullPage: true});
    // Native modal traps keyboard focus.
    for (let i = 0; i < 8; i++) await preview.keyboard.press("Tab");
    assert.equal(await preview.evaluate(() => component.shadowRoot.querySelector("dialog").contains(component.shadowRoot.activeElement)), true);
    await preview.emulateMedia({reducedMotion: "reduce"});
    assert.equal(await preview.locator(".icon-button").first().evaluate(el => getComputedStyle(el).transitionDuration), "0s");
    await preview.close();
  }
  assert.deepEqual(errors, []);
  console.log("Panel passed: masked reads, reveal expiry/blur races, stable DOM, dialogs/focus, add/rename/remove/cancel, duplicate prevention, delayed feedback, error recovery, local search, themes, 320/390/1100px layouts, reduced motion.");
} finally { await browser.close(); }
