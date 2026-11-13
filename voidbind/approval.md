# Action approval

A person approves **one described action** on a member device: the approval is bound to the
action's digest, its resource, the approval's lifetime and a number the person matched. It is
how a broker gets a human decision before doing something (minting a credential, logging a
person in to an app, a step-up, a consent).

| Part | Status | Implemented by |
| --- | --- | --- |
| The action, its digest, the challenge preimage, the assertion | stable | Go core `approval` (byte layer and vectors) |
| The broker's challenge, handle, approval and consumption rules | stable | Go core `approval.Broker` |
| The opaque `approve` tuple and the authenticated fetch (`/approval/fetch-nonce`, `/approval/fetch`) | stable | Go core `approval.Handler`, mounted by the reference broker |
| The broker's approve and handle routes (`/approval/approve`, `/v1/approval/handle`) | **draft** (pilot) | reference broker, pilot-only |
| Back-channel approval for third-party RPs | **draft** | see [oidc.md](oidc.md#back-channel-approval-ciba) |

## The action

| Field | Rule |
| --- | --- |
| `kind` | a short verb, `[a-z][a-z0-9-]{0,31}` (for example `deploy`, `login`, `step-up`) |
| `resource` | a scope ([grants.md](grants.md#scopes)), for example `do:team/ops` |
| `summary` | the sentence the device displays: 1–1024 bytes of valid UTF-8, with no control characters and no bidirectional formatting characters (U+202A–U+202E, U+2066–U+2069, U+200E, U+200F, U+061C). Digested as given; never normalised |
| `params` | opaque bytes, at most 64 KiB, possibly empty. The broker canonicalises them once when it builds the action; the device recomputes the digest over the bytes it fetched without canonicalising again |

```
action_digest = SHA-256( frame("void-which-binds/approval/action/v1")
                         ‖ frame(kind) ‖ frame(resource) ‖ frame(summary) ‖ frame(params) )
```

`frame(p) = uint64_be(len(p)) ‖ p`. On the wire (`examples/approval-action.json`) `params` is
base64url (`""` for none).

## The challenge

The broker creates one challenge per ceremony:

| Field | Rule |
| --- | --- |
| `id` | 32 lowercase hex (16 random bytes) |
| `nonce` | 32 random bytes, not all zero |
| `audience` | the broker's origin |
| `issued_at`, `expires_at` | the challenge's own window: 2 minutes |
| match number | the true number, in `[0, 100)`. **Never sent to the device** |
| `candidates` | three distinct numbers in `[0, 100)` including the true one, shuffled |
| `action_digest` | the stored action's digest |
| `resource` | the stored action's resource |
| `ttl` | the life of the approval once given, whole seconds, `0 ≤ ttl ≤ 3600`. `0` means **single use** |

Number matching is **mandatory**; there is no un-numbered approval. The true number is shown on
the **initiating surface** (the screen or CLI that asked for the action), never on the device.

The device signs, under its member key:

```
frame("void-which-binds/approval/challenge/v1") ‖ frame(id) ‖ frame(nonce) ‖ frame(audience)
‖ frame(uint64_be(expires_at)) ‖ frame(uint64_be(chosen number)) ‖ frame(action_digest)
‖ frame(resource) ‖ frame(uint64_be(ttl))
```

An Ed25519 key signs the preimage directly (64 raw bytes). A passkey asserts over the WebAuthn
challenge derived from it with domain `void-which-binds/approval/challenge/v1` and sends the
envelope ([grants.md](grants.md#the-webauthn-member-key)). Before signing, the device MUST
recompute the digest from the fetched action and require it, and the resource, to match the
fetched challenge: it signs only what it displayed.

## The `approve` tuple

To reach the person, the broker mints a **handle** (32 random bytes, base64url, 43 characters)
per (challenge, person) and wakes that person's devices with:

```
void-which-binds:approve?h=<handle>
```

(`examples/approval-approve-tuple.json`.) The tuple names no RP, no challenge id, no action and no
number: it points at nothing a stranger can read. A device parses it by **exact match**: the
prefix followed by exactly 43 canonical base64url characters, no other parameter, no
percent-encoding, no padding, no fragment. The device sends the fetch to the broker it is
enrolled at (trying each in turn if it has several); the audience binding makes a proof for one
broker useless at another. A handle resolves only while its challenge is pending and unexpired.

## The authenticated fetch

A handle alone reveals nothing. To read the challenge and the action, the device proves it holds
a current member key of the person the handle was minted for.

1. `POST /approval/fetch-nonce`, no input → `200 {"nonce": "<base64url 32 bytes>"}`
   (`examples/approval-fetch-nonce-response.json`). Single use, valid for 2 minutes.
2. The device signs, under its member key (passkey domain `void-which-binds/approval/fetch/v1`):

   ```
   frame("void-which-binds/approval/fetch/v1") ‖ frame(audience) ‖ frame(handle) ‖ frame(nonce)
   ```

   with `handle` and `nonce` as their raw 32 bytes.
3. `POST /approval/fetch` (`examples/approval-fetch-request.json`):

   | Member | Type | Req. | Meaning |
   | --- | --- | --- | --- |
   | `handle` | base64url | yes | from the tuple |
   | `nonce` | base64url | yes | from step 1 |
   | `credential` | token | yes | the device's admitting op (sovereign) or the roster `enrol` of its key (managed) |
   | `ops` | array of op token | no | presented person ops |
   | `roster` | array of roster op token | no | presented roster ops |
   | `proof` | base64url | yes | the signature (or passkey envelope) from step 2 |

The broker, in this order: spends the nonce (whatever the outcome), resolves the handle to a
pending challenge and its person, authenticates the fetcher through the org path under **its own
configured org** ([roster.md](roster.md#the-verifier-path), nothing persisted) and requires it
to be that person, then verifies the proof. Success is `200`
(`examples/approval-fetch-response.json`):

```json
{"challenge": {"id", "nonce", "audience", "issued_at", "expires_at", "candidates",
               "action_digest", "resource", "ttl"},
 "action":    {"kind", "resource", "summary", "params"}}
```

with base64url `nonce`, `action_digest` and `params`, and **no match number**.

**One refusal.** Every failure (unknown handle, expired or already approved challenge, missing or
bad proof, spent or expired nonce, a valid key of the wrong person) is the same response:
`404` with exactly the body `{"error":"not_found"}`. The broker logs the specific reason
(`unknown_handle`, `fetch_unauthenticated`, `bad_fetch_proof`, `fetch_nonce_spent`,
`fetch_wrong_approver`, or a rate-limit word) and never returns it. A fetch writes nothing but
the spent nonce, and authorises nothing.

## Approving

**Status: draft (pilot route).** The reference broker accepts:

`POST /approval/approve` (`examples/broker-approve-request.json`):

```json
{"challenge_id": "<id>", "assertion": {"credential", "ops"?, "roster"?, "sig", "match_number"}}
```

The assertion (`examples/approval-assertion.json`) carries the approver's credential and
presented op sets as in the fetch, `sig` (base64url: 64 Ed25519 bytes, or a passkey envelope),
and the **required** `match_number` the person chose. Success is `200 {"status":"approved"}`. A
refusal is `{"error": "<word>"}` (`examples/broker-error.json`).

The broker verifies under the challenge's lock and **writes nothing until every check passes**:

| Step | Check | Refusal (reference HTTP status) |
| --- | --- | --- |
| 1 | the challenge exists, is not already approved, is not expired | `unknown_challenge` (404), `already_approved` (409), `challenge_expired` (403) |
| 2 | `match_number` present and equal to the true number | `malformed` (400), `number_mismatch` (403) |
| 3 | the **stored** action's digest equals the challenge's digest and its resource the challenge's resource | `digest_mismatch`, `resource_mismatch` (409) |
| 4 | the approver is a current member of a person with standing in the broker's own org, evaluated in memory | `approver_not_member` (401), `approver_removed`, `approver_not_on_roster` (403) |
| 5 | the signature verifies under the approver's key over the preimage | `bad_assertion` (401) |
| 6 | the challenge's resource is within the policy of the approver's role, from the same evaluation | `approver_not_authorised` (403) |
| 7 | commit the approver's fresh ops, mark the challenge approved, store the approval record | |

The approval record (`id, action_digest, resource, person, approver, approved_at,
not_after = approved_at + ttl, single_use = (ttl == 0), consumed`) is never returned to a client
and never presented back as a bearer credential. The component that performs the action
**consumes** it atomically: the digest must match (`digest_mismatch`); a single-use approval is
consumed exactly once (`approval_consumed` after); a `ttl > 0` approval authorises every
consumption while `now < not_after` (`approval_expired` after). An unknown approval id is
`unknown_approval`.

A delegation can never satisfy an approval: an approval needs a person's member key.

### Minting a handle (pilot)

`POST /v1/approval/handle`, authenticated with the `Device` credential, body
`{"challenge_id": "<id>"}` → `{"handle": "<base64url>"}`
(`examples/broker-handle-request.json`, `examples/broker-handle-response.json`). It lets a
person's own CLI obtain the handle the broker would have pushed, for a challenge they are
eligible to approve. It is a pilot aid, not part of the stable flow.

## Security considerations

- The device signs the digest of the action it displayed, so a broker that changes the action
  after display gets an approval that verifies against nothing.
- Number matching binds the approval to the initiating surface: a person woken by a push they
  did not start has no screen showing the number.
- The opaque tuple and the authenticated fetch keep the action's details away from push
  providers and wrongly routed notifications.
- An approval does not escalate: the approver's own role must cover the resource.
- Single-use consumption is the atomic gate against two consumers racing.
