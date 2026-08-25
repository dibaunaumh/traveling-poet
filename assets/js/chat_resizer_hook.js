// Draggable divider that resizes the chat sidebar by writing a CSS custom
// property (--chat-width) onto <html>. The width lives on document.documentElement
// — an element LiveView never patches — so it survives morphdom DOM patches that
// re-render the sidebar on every chat stream delta. The sidebar panel's inline style
// is a static `width: var(--chat-width, 24rem)` reference (byte-identical on every
// server render), so LiveView leaves it untouched while the var drives the real width.

const STORAGE_KEY = "chatSidebarWidth";
const MIN_WIDTH = 300;
const DEFAULT_WIDTH = 384; // matches Tailwind w-96 / 24rem

// Keep the Unity pane usable: cap how wide the sidebar can get.
function maxWidth() {
  return Math.min(900, Math.max(MIN_WIDTH, window.innerWidth - 360));
}

function clamp(px) {
  return Math.round(Math.min(maxWidth(), Math.max(MIN_WIDTH, px)));
}

function setWidth(px) {
  document.documentElement.style.setProperty("--chat-width", px + "px");
}

function currentWidth() {
  const v = parseInt(
    getComputedStyle(document.documentElement).getPropertyValue("--chat-width"),
    10,
  );
  return Number.isFinite(v) ? v : DEFAULT_WIDTH;
}

const ChatResizer = {
  mounted() {
    // Restore the persisted width (re-clamped to the current viewport) on mount.
    const stored = parseInt(localStorage.getItem(STORAGE_KEY), 10);
    setWidth(clamp(Number.isFinite(stored) ? stored : DEFAULT_WIDTH));

    this.panel = document.getElementById("chat-sidebar-panel");

    this.onPointerMove = (e) => {
      // The sidebar is flush against the viewport's right edge, so its width is
      // the distance from the cursor to the panel's right edge.
      const right = this.panel
        ? this.panel.getBoundingClientRect().right
        : window.innerWidth;
      setWidth(clamp(right - e.clientX));
    };

    this.endDrag = (e) => {
      this.el.removeEventListener("pointermove", this.onPointerMove);
      this.el.removeEventListener("pointerup", this.endDrag);
      this.el.removeEventListener("pointercancel", this.endDrag);
      try {
        if (e && e.pointerId != null && this.el.hasPointerCapture(e.pointerId)) {
          this.el.releasePointerCapture(e.pointerId);
        }
      } catch (_) {}

      if (this.panel) this.panel.classList.remove("chat-resizing");
      document.body.classList.remove("chat-resizing-active");

      localStorage.setItem(STORAGE_KEY, String(currentWidth()));

      // Nudge Unity to re-fit its canvas. rAF so it reads the post-drag layout.
      requestAnimationFrame(() => window.dispatchEvent(new Event("resize")));
    };

    this.onPointerDown = (e) => {
      if (e.button !== undefined && e.button !== 0) return; // primary button only
      e.preventDefault();

      // Capture the pointer on the handle so the drag isn't swallowed by the
      // Unity canvas when the cursor passes over it.
      this.el.setPointerCapture(e.pointerId);

      if (this.panel) this.panel.classList.add("chat-resizing");
      document.body.classList.add("chat-resizing-active");

      this.el.addEventListener("pointermove", this.onPointerMove);
      this.el.addEventListener("pointerup", this.endDrag);
      this.el.addEventListener("pointercancel", this.endDrag);
    };

    // Re-clamp a previously-wide sidebar when the window shrinks.
    this.onWindowResize = () => setWidth(clamp(currentWidth()));

    this.el.addEventListener("pointerdown", this.onPointerDown);
    window.addEventListener("resize", this.onWindowResize);
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown);
    window.removeEventListener("resize", this.onWindowResize);
    document.body.classList.remove("chat-resizing-active");
    // Deliberately keep --chat-width so reopening the sidebar restores the width.
  },
};

export default ChatResizer;
