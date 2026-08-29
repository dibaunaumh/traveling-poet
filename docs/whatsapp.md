# WhatsApp setup (Meta Cloud API)

The app code is done; what's left is account setup in Meta's dashboard, which
can't be scripted. Roughly 30 minutes, and the test tier works immediately —
no business verification needed to message up to 5 numbers you nominate.

## 1. Create the Meta app

1. <https://developers.facebook.com/apps> → **Create app** → type **Business**.
2. Add the **WhatsApp** product. It provisions a free **test phone number**
   and a temporary 24h access token.
3. Under *WhatsApp → API setup*, note:
   - **Phone number ID** → `WHATSAPP_PHONE_NUMBER_ID` (the id, not the number)
   - the test number itself → `WHATSAPP_BUSINESS_NUMBER` (digits only, with
     country code, e.g. `15550123456`)
4. Add each beta tester's number under **To** → *Manage phone number list*.
   Each one gets a WhatsApp confirmation code. Test-tier limit: 5 recipients.

## 2. Permanent access token

The 24h token is fine for a first smoke test, but it expires. For anything
lasting:

*Business Settings → Users → System users* → add a system user with the
**Admin** role → **Generate new token** → pick the app, no expiry, scopes
`whatsapp_business_messaging` and `whatsapp_business_management`.

That token → `WHATSAPP_ACCESS_TOKEN`.

## 3. App secret and verify token

- *App settings → Basic → App secret* → `WHATSAPP_APP_SECRET`. Every inbound
  webhook is HMAC-checked against this; without it the endpoint rejects
  everything, by design.
- `WHATSAPP_VERIFY_TOKEN` is any string you invent — Meta echoes it back once
  during webhook subscription.

## 4. Subscribe the webhook

*WhatsApp → Configuration → Webhook → Edit*:

- Callback URL: `https://poet.travel/webhooks/whatsapp`
- Verify token: whatever you set as `WHATSAPP_VERIFY_TOKEN`

Set the secrets on Fly **before** clicking Verify — the handshake hits the
running app:

```sh
fly secrets set -a traveling-poet-dev \
  WHATSAPP_ACCESS_TOKEN='…' WHATSAPP_PHONE_NUMBER_ID='…' \
  WHATSAPP_BUSINESS_NUMBER='…' WHATSAPP_VERIFY_TOKEN='…' \
  WHATSAPP_APP_SECRET='…'
```

Then subscribe to the **messages** field. Delivery/read statuses are ignored
by the controller; leave them off to keep the log quiet.

## 5. Message templates

WhatsApp only allows free-form text within 24h of the user's last message to
us. Everything the app initiates — the daily publish note, the credits
warnings — therefore goes out as a pre-approved template.

Register these three under *WhatsApp → Message templates*, category
**Utility**, language **English (en)**. The names and the variable order must
match exactly; `Messaging.Notification` fills them positionally.

| Name | Body |
| --- | --- |
| `journal_published` | `🖋 {{1}} published today's entry from {{2}}. Read it here: {{3}}` |
| `credits_low` | `⏳ {{1}} has about {{2}} credits left — a few days of travel. Top up: {{3}}` |
| `credits_empty` | `💤 {{1}} has run out of credits and is resting. Top up: {{2}}` |

Utility templates usually clear review inside a day. Until they're approved,
inbound chat works fine and notifications fail with a logged warning — the
Telegram half is unaffected either way.

**Cost:** each template message is billed per message (utility rate, varies by
recipient country). One publish note per user per day is the volume driver.
Free-form replies inside the 24h window are not billed separately.

## 6. Going past the test tier

To message arbitrary numbers you need Meta **business verification** plus a
real phone number registered to the WhatsApp Business Account (a number not
already tied to a personal WhatsApp account). Same code path — only
`WHATSAPP_PHONE_NUMBER_ID` and `WHATSAPP_BUSINESS_NUMBER` change.

## How pairing works

Same shape as Telegram, since WhatsApp has no `/start`:

1. The app mints a 15-minute token and renders
   `https://wa.me/<number>?text=PAIR%20<token>`.
2. The user opens it and sends the prefilled message.
3. The webhook matches the token and binds their `wa_id` to their account.

`Messaging.Inbound` accepts both `PAIR <token>` and `/start <token>` on either
provider, so the two flows share one code path.
