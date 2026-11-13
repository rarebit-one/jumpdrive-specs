# Web QR login

**Status: stable.** Go core `weblogin` (RP broker, HTTP handler, the device's fetch and approve);
the public browser client `void-which-binds-web`; the Kotlin device library (`LoginQr`).

A browser is logged in to an RP when one of a pinned person's devices signs a one-time challenge
(the "WhatsApp Web" pattern). The browser never handles a key; the device never handles a
password.

**v1** is QR-only: the device scans the browser's screen, which binds the approval to that
screen. **v2 (number matching)** is for logins that reach the device without a scan (a wake
from the notify plane): the browser shows a number, the device shows candidates, and the
approval is cryptographically bound to the number the person chose. v1 is unchanged by v2.

## Parties and routes

The RP serves, under its base URL:

| Route | Caller | Purpose |
| --- | --- | --- |
| `POST /login` | browser | create a v1 login |
| `POST /login?mode=number-match` | browser | create a v2 login |
| `GET /login/{id}` | browser | poll status |
| `GET /login/{id}/challenge` | device | fetch what to sign |
| `POST /login/{id}/approve` | device | submit the signed approval |

## The QR and the wake tuple

```
void-which-binds:login?id=<login id>&rp=<RP base URL>
```

The tuple names only the RP and the login id; the device fetches the full challenge, so the RP
is the single source of truth for what is signed. The same string is what a wake carries for a
push login. A device MUST refuse a different scheme or opaque part, or a missing `rp` or `id`.

## Messages

### Create

`POST /login[?mode=number-match]`, no body → `200` (`examples/weblogin-create-response.json`):

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | the login id: 32 lowercase hex (16 random bytes) |
| `qr` | string | yes | the login tuple above |
| `match_number` | int | v2 only | the number the **browser** displays, in `[0, 100)` |

An RP without v2 ignores `mode`; the client then gets no `match_number` and proceeds as v1.

### Poll

`GET /login/{id}` → `200` (`examples/weblogin-poll-response.json`), or `404` for an unknown id:

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `status` | string | yes | `pending`, `approved` or `expired` |
| `token` | string | when `approved` | an opaque, short-lived session credential (30 minutes in the reference RP) |
| `user` | key | when `approved` | the authenticated person id |

The token is the RP's own session credential, not a protocol primitive. The browser client
sends it as `Authorization: Bearer <token>`, and as a `token` query parameter on an
`EventSource` URL, which cannot set headers.

### Challenge

`GET /login/{id}/challenge` → `200` (`examples/weblogin-challenge-response.json`); `404` unknown,
`410` expired:

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | the login id |
| `nonce` | base64url | yes | 32 fresh random bytes |
| `audience` | string | yes | the RP's identity (its origin) |
| `expires_at` | int | yes | the challenge's expiry, 2 minutes after creation |
| `candidates` | array of int | v2 only | three distinct numbers in `[0, 100)`, the true one among them, shuffled. The true number is **never** sent to the device |

### Approve

`POST /login/{id}/approve` (`examples/weblogin-approve-request.json`), body at most 96 KiB:

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `cert` | op token | yes | the device's **admitting op** (a v3 add or a cert; the name is historical) |
| `ops` | array of op token | no | membership ops the device knows, at most 64 |
| `sig` | base64url | yes | Ed25519 signature by the device key over the preimage below |
| `match_number` | int | v2: yes; v1: MUST be absent | the number the person tapped |

The device signs, with its device key, the framed preimage over the challenge **as fetched**
(and, for v2, the number the person chose):

```
v1:  frame("void-which-binds/weblogin/challenge/v1") ‖ frame(id) ‖ frame(nonce)
     ‖ frame(audience) ‖ frame(uint64_be(expires_at))
v2:  frame("void-which-binds/weblogin/challenge/v2") ‖ frame(id) ‖ frame(nonce)
     ‖ frame(audience) ‖ frame(uint64_be(expires_at)) ‖ frame(uint64_be(match_number))
```

`frame(p) = uint64_be(len(p)) ‖ p`; `id` and `audience` are their UTF-8 bytes, `nonce` its raw
32 bytes.

Responses: `204` approved; `400` an unreadable body; `401` not authorised (any verification
failure, including more than 64 ops); `404` unknown login; `410` expired; `409` already
approved.

## What the RP checks

Against the **stored** challenge, never fields the client resends:

1. For v2, `match_number` is present and equals the stored true number (`number_mismatch`);
   for v1 it is absent (`malformed`: no downgrade, no silently ignored field).
2. The admitting op authenticates the device as a current member of a **pinned** person,
   evaluated over the RP's log ∪ the presented ops, in memory
   ([identity.md](identity.md#what-the-rp-checks-in-order) steps 1–4).
3. `sig` verifies under that device key over the stored challenge's preimage (for v2, bound to
   the true number). This is the login's possession proof (`bad_assertion`).
4. The challenge has not expired (`challenge_expired`).
5. Only then record the presented ops and move the login to `approved`. A login is single use: a
   second approval is refused. A failed approval leaves the login `pending`, so a mis-scan or a
   rejected forgery does not lock out the honest device.

## Security considerations

- The nonce makes each approval unique; the audience stops an approval for one RP being replayed
  at another; the 2-minute expiry bounds the window.
- In v2 the device cannot tell which candidate is right without the browser's screen, so a push
  an attacker triggered is approved only by a lucky guess (1 in 3 per attempt). RPs SHOULD
  rate-limit login creation per person.
- A device SHOULD check that the fetched `audience` names the RP whose origin is in the tuple it
  scanned or was woken with, and show that origin to the person before signing. (The reference
  CLI stand-in does not check this; the binding is enforced by the RP's own audience check.)
- The session token is a bearer credential; carrying it in a URL is acceptable only because it
  is per-login and short-lived.

## Code and documentation notes

- ADR-0003 describes the assertion as `{cert, sig}`; the code adds `ops` and, for v2,
  `match_number`.
- The `void-which-binds-web` README cites "ADR-0006" for the base protocol and "ADR-0009 push";
  in the Go core the base protocol is ADR-0003, number matching ADR-0006 and the push plane
  ADR-0005 (ADR-0009 is the token-type claim).
