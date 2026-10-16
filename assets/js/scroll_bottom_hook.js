// Keeps the chat pinned to its newest message, but only while the reader is
// already at the bottom. It used to jump there on every DOM change, so nobody
// could scroll back through the conversation while a reply was streaming in:
// each token yanked them down again, and on a phone it fought the momentum of
// their own scroll.
//
// Opening the chat lands at the end: the first scroll happens as the hook
// mounts, before the overlay has been sized to the screen and the hands have
// been drawn, so it is done again a frame later, once fonts are in, and
// whenever the box itself changes size (the keyboard coming up shrinks it;
// the reader expects to stay at the end while typing).
const NEAR_BOTTOM_PX = 80;

const ScrollBottom = {
  mounted() {
    this.pinned = true;
    this.onScroll = () => {
      const { scrollTop, scrollHeight, clientHeight } = this.el;
      this.pinned = scrollHeight - scrollTop - clientHeight < NEAR_BOTTOM_PX;
    };
    this.el.addEventListener("scroll", this.onScroll, { passive: true });
    this.settle();
    this.observer = new MutationObserver(() => this.follow());
    this.observer.observe(this.el, { childList: true, subtree: true });
    if (window.ResizeObserver) {
      this.resizer = new ResizeObserver(() => this.follow());
      this.resizer.observe(this.el);
    }
  },
  updated() {
    this.follow();
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
    if (this.resizer) this.resizer.disconnect();
    this.el.removeEventListener("scroll", this.onScroll);
  },
  follow() {
    if (this.pinned) this.scrollToBottom();
  },
  settle() {
    this.scrollToBottom();
    requestAnimationFrame(() => this.follow());
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(() => this.follow());
    }
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

export default ScrollBottom;
