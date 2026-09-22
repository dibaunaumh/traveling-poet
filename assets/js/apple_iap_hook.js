// Credit packs in the iOS app, sold by StoreKit (Settings, Credits).
//
// The server names the packs and this account's purchase token; the device
// knows what they cost here, in this storefront's currency, so the prices
// shown are StoreKit's own. A purchase gives back a transaction signed by
// Apple. It goes to the server, which verifies it and credits the pack, and
// only then is StoreKit told the purchase is finished: until that happens
// StoreKit keeps redelivering it, so a credit cannot be lost to a dropped
// connection (native.js picks up the redelivery at the next launch).
import {call, settle} from "./native"

const AppleIAP = {
  async mounted() {
    this.packs = this.el.querySelector("[data-role=packs]")
    this.status = this.el.querySelector("[data-role=status]")
    this.products = JSON.parse(this.el.dataset.products)
    this.token = this.el.dataset.accountToken

    try {
      const {products} = await call("PoetNative", "products", {ids: this.products.map((p) => p.product_id)})
      const priced = new Map(products.map((p) => [p.id, p.displayPrice]))
      // Only what the App Store actually has on sale is offered.
      const onSale = this.products.filter((p) => priced.has(p.product_id))
      if (onSale.length === 0) return this.say("Credit packs are not available right now.")
      onSale.forEach((p) => this.packs.appendChild(this.button(p, priced.get(p.product_id))))
    } catch (err) {
      console.warn("[iap] products", err)
      this.say("Credit packs are not available right now.")
    }
  },

  button(product, price) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn btn-outline btn-sm w-full flex-col h-auto py-2"
    button.dataset.product = product.product_id

    const credits = document.createElement("span")
    credits.className = "font-semibold"
    credits.textContent = `${product.credits} credits`
    const cost = document.createElement("span")
    cost.className = "text-xs opacity-70"
    cost.textContent = price

    button.append(credits, cost)
    button.addEventListener("click", () => this.buy(product))
    return button
  },

  async buy(product) {
    if (this.busy) return
    this.busy = true
    this.packs.querySelectorAll("button").forEach((b) => (b.disabled = true))
    this.say("")

    try {
      const result = await call("PoetNative", "purchase", {
        productId: product.product_id,
        appAccountToken: this.token,
      })

      if (result.status === "purchased") {
        const outcome = await settle(result)
        this.say(outcome.finish ? `${product.credits} credits added.` : "That purchase could not be added. It has not been lost: it will be tried again.")
      } else if (result.status === "pending") {
        // Ask to Buy: someone else has to approve it first.
        this.say("Waiting for approval. The credits arrive as soon as it is given.")
      }
      // "cancelled": the reader changed their mind; nothing to say.
    } catch (err) {
      console.warn("[iap] purchase", err)
      this.say("The purchase did not go through. You have not been charged.")
    } finally {
      this.busy = false
      this.packs.querySelectorAll("button").forEach((b) => (b.disabled = false))
    }
  },

  say(text) {
    this.status.textContent = text
  },
}

export default AppleIAP
