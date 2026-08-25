// Auto-resizing textarea for chat input. Also folds in the UnityKeyboardGuard
// behavior (focus/blur toggle of a global keystroke-blocking flag) so Unity
// WebGL doesn't swallow keys while the chat input is focused.

let guarded = false;
let chatInputEl = null;

function handleKey(e) {
  if (!guarded) return;
  // Submit on Enter (Shift+Enter inserts a newline). Done at capture phase
  // because the guard below stops propagation, so a listener on the textarea
  // itself would never fire.
  if (
    e.type === "keydown" &&
    e.target === chatInputEl &&
    e.key === "Enter" &&
    !e.shiftKey &&
    !e.isComposing
  ) {
    e.preventDefault();
    chatInputEl.form?.requestSubmit();
  }
  e.stopImmediatePropagation();
}

window.addEventListener("keydown", handleKey, true);
window.addEventListener("keyup", handleKey, true);
window.addEventListener("keypress", handleKey, true);

function resize(el) {
  el.style.height = "auto";
  el.style.height = el.scrollHeight + "px";
}

const ChatInput = {
  mounted() {
    chatInputEl = this.el;
    this.onFocus = () => (guarded = true);
    this.onBlur = () => (guarded = false);
    this.onInput = () => resize(this.el);
    this.onReset = () => requestAnimationFrame(() => resize(this.el));

    this.el.addEventListener("focus", this.onFocus);
    this.el.addEventListener("blur", this.onBlur);
    this.el.addEventListener("input", this.onInput);
    this.el.form?.addEventListener("reset", this.onReset);

    resize(this.el);
  },
  updated() {
    resize(this.el);
  },
  destroyed() {
    this.el.form?.removeEventListener("reset", this.onReset);
    if (chatInputEl === this.el) chatInputEl = null;
  },
};

export default ChatInput;
