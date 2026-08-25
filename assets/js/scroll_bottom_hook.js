const ScrollBottom = {
  mounted() {
    this.scrollToBottom();
    this.observer = new MutationObserver(() => this.scrollToBottom());
    this.observer.observe(this.el, { childList: true, subtree: true });
  },
  updated() {
    this.scrollToBottom();
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

export default ScrollBottom;
