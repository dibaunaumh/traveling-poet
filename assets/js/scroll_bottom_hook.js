// Keeps the chat pinned to its newest message, but only while the reader is
// already at the bottom. It used to jump there on every DOM change, so nobody
// could scroll back through the conversation while a reply was streaming in:
// each token yanked them down again, and on a phone it fought the momentum of
// their own scroll.
const NEAR_BOTTOM_PX = 80;

const ScrollBottom = {
  mounted() {
    this.pinned = true;
    this.onScroll = () => {
      const { scrollTop, scrollHeight, clientHeight } = this.el;
      this.pinned = scrollHeight - scrollTop - clientHeight < NEAR_BOTTOM_PX;
    };
    this.el.addEventListener("scroll", this.onScroll, { passive: true });
    this.scrollToBottom();
    this.observer = new MutationObserver(() => this.follow());
    this.observer.observe(this.el, { childList: true, subtree: true });
  },
  updated() {
    this.follow();
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
    this.el.removeEventListener("scroll", this.onScroll);
  },
  follow() {
    if (this.pinned) this.scrollToBottom();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

export default ScrollBottom;
