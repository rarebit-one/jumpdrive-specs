# Grants and delegation

Two signed, expiring statements of authority, with different trust roots:

- a **capability grant** is signed by a key the verifier has **pinned** as an issuer;
- a **delegation grant** is signed by a **member key of a person**, judged by evaluating that
  person's membership and their standing in an organisation's roster, and lends a subset of the
  person's authority to an **agent key** at one broker.

They are separate `typ`s with separate verifiers on purpose. A verifier MUST NOT route one to
the other's code: a delegation read as a grant would treat its member key as a pinned issuer.

## Capability grant

**Status: stable.** Go core `grant`; used beside the `Device` credential through the
`Void-Which-Binds-Grant` header.

Body (`examples/grant-body.json`):

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `v` | int | yes | 1 |
| `typ` | string | yes | `void-which-binds.grant` |
| `iss` | key | yes | the issuer's `ed25519:` key, canonical; also the signing key |
| `prn` | string | yes | the principal the grant is for (RP-defined, typically a device or person key) |
| `res` | string | yes | the resource (RP-defined) |
| `cap` | array of string | yes | capabilities, sorted and de-duplicated, at least one. Defined: `read`, `write`. `read` never implies `write` |
| `iat` | int | yes | issued at |
| `exp` | int | yes | expiry, after `iat`, and `exp − iat` at most **24 hours** |

The 24-hour cap is the revocation window: a grant revoked at one site is honoured at a site
that cannot be reached for at most its remaining life. A minter MUST refuse to sign a longer
grant. (The Go verifier checks only the window, not the cap; a verifier MAY also refuse a grant
whose `exp − iat` exceeds 24 hours.)

### Verification

In this order, each with its own refusal word:

1. Parse (`malformed`); `typ` (`wrong_type`); `v` is 1 and `iss` is a canonical key
   (`malformed`).
2. Select the pinned key **by `iss`** and refuse an issuer that is not pinned
   (`unknown_issuer`). Verify the signature under it (`bad_signature`). Every field is a claim
   until this step passes.
3. `prn` equals the request's principal (`principal_mismatch`); `res` equals the request's
   resource (`resource_mismatch`); `cap` contains the requested capability
   (`capability_denied`).
4. Time, last, with a **5-minute** margin that only shortens the window: `not_yet_valid` while
   `now + 5 min < iat`; `expired` once `now ≥ exp − 5 min`.

## Delegation grant

**Status: stable.** Go core `delegation` (mint and verify); verified by the reference broker on
every agent request.

A person's member key (an Ed25519 device key, or a passkey) lends scoped, expiring authority to
an agent key, at **one broker** (`aud`) for **one organisation** (`org`).

Body (`examples/delegation-body.json`), members in this order:

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `v` | int | yes | 1 |
| `typ` | string | yes | `void-which-binds.delegation` |
| `usr` | person id | yes | the person on whose behalf: `ed25519:` (sovereign) or `mp:` (managed). MUST be on `org`'s roster |
| `org` | key | yes | the org id the broker serves |
| `iss` | member key | yes | the signing key: a current member of `usr` (`ed25519:` or `webauthn:es256:`). Never `usr` or `org` |
| `prn` | key | yes | the agent key, `ed25519:`. MUST NOT be a member key of `usr`, nor `usr`, `org` or `iss` |
| `aud` | string | yes | the broker's audience (its origin), compared byte for byte |
| `scp` | array of scope | yes | 1–32 scopes, **sorted by byte order and de-duplicated**; a verifier refuses a non-canonical list |
| `jti` | base64url | yes | 16 random bytes chosen by the minter |
| `non` | base64url | yes | the 32-byte **broker nonce** (below) |
| `iat` | int | yes | issued at, positive |
| `exp` | int | yes | `exp − iat` at most **24 hours**, enforced at mint **and** at verify |

The body MUST be exactly the canonical encoding of its claims in this order; anything else
(reordered, spaced, duplicate or unknown keys) is `malformed`. There is no re-delegation: an
agent key is never a member, so it can never be an `iss`.

### Scopes

A scope is `<ns>:<path>`, where `ns` matches `[a-z][a-z0-9-]{0,31}` and `path` matches
`[a-z0-9][a-z0-9._/-]{0,127}`. Scopes are compared byte for byte, with **no wildcards and no
implication**: `do:team/ops` does not imply `do:team/ops/deploy`, and `app:write` does not imply
`app:read`. A string outside the grammar is refused, never folded into one inside it. The
namespaces are registered by the broker's policy, not by this protocol. The `oidc:` namespace is
reserved for [oidc.md](oidc.md) and MUST NOT appear in a delegation.

### The broker nonce

Every delegation carries a nonce the broker drew immediately before the signing ceremony, so no
delegation can be minted ahead of time.

`POST /v1/delegation/nonce` (reference broker; unauthenticated, rate-limited), no body →
`200 {"nonce": "<43 base64url>"}` (`examples/delegation-nonce-response.json`). Over the rate
limit is `429 {"error":"rate_limited"}`.

- A nonce is valid for a delegation whose `iat` lies in `[issued − 5 min, issued + 5 min]`.
  Otherwise, or if this broker never issued it, `nonce_invalid`.
- The first delegation that verifies with a nonce **binds** it to its `jti` (an atomic
  compare-and-set at commit). Another `jti` with the same nonce is `nonce_reused`.
  Re-presenting the same delegation is the normal case and verifies.
- The broker keeps a nonce for 5 min + 24 h after issue.

### Agent proof of possession

With every request the agent presents a second token signed by `prn`
(`examples/delegation-pop-body.json`):

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `v` | int | yes | 1 |
| `typ` | string | yes | `void-which-binds.delegation-pop` |
| `dlg` | base64url | yes | SHA-256 of the delegation's **body bytes** (not the token: a P-256 signature is malleable, so hashing the token would let a third party mint a second valid token for the same grant) |
| `aud` | string | yes | the broker's audience |
| `iat` | int | yes | issued at |
| `exp` | int | yes | at most 2 minutes after `iat` |

Its window follows the possession proof's rule: 30 seconds of tolerance on the not-yet-valid
side, strict expiry. A proof is not bound to a method or URL in v1, so it is replayable to
another endpoint of the same broker by someone who already holds it, for at most 2 minutes.

### Transport

```
Void-Which-Binds-Delegation: <delegation token>
Void-Which-Binds-Delegation-Proof: <proof token>
Void-Which-Binds-Membership: <person ops>        (sovereign issuer only; at most 64)
```

A delegation request carries **no** `Void-Which-Binds-Roster` header and the broker does not
read one: the broker judges the person against its own recorded roster, so nothing an agent
presents can change that standing.

### Verification

The broker writes nothing until every check has passed. In order:

1. Parse both tokens. `typ` exactly right on both (`wrong_type`); `v` is 1, claims complete,
   scopes canonical, `exp − iat ≤ 24 h`, canonical body (`malformed`). A missing or unparseable
   proof is `pop_invalid`.
2. **Proof.** Verify it under `prn`; `dlg` matches; `aud` is this broker; inside its window
   (`pop_invalid`).
3. **Person.** `org` is the broker's own org and `usr` holds standing on its roster now,
   evaluated over the broker's recorded roster with nothing presented
   ([roster.md](roster.md#how-a-relying-party-trusts-persons-through-a-roster)). Any failure,
   a frozen org, or a person kind that disagrees with the shape of `usr`, is `unknown_user`.
   A delegation with `iat` at or before the moment the org's current authority key took over (a
   re-root, [roster.md](roster.md#re-roots)) is also `unknown_user`.
4. **Issuer.** For a sovereign `usr`: evaluate `usr`'s membership over stored ∪ presented ops;
   `iss` must be a member (`issuer_removed` if it was removed, else `issuer_not_member`), and
   `prn` must not be (`principal_is_member`). For a managed `usr`: `iss` must be one of the
   person's live enrolled roster keys (`issuer_not_member`), `prn` must not be
   (`principal_is_member`), and every entry of `scp` must be within the person's role policy
   (`scope_exceeds_role`).
5. **Signature** under `iss`, dispatched on its key kind (`bad_signature`): Ed25519 over the
   body, or a WebAuthn envelope (below) with domain `void-which-binds.delegation`.
6. **Audience and window.** `aud` matches (`audience_mismatch`); the grant window with the
   5-minute shortening margin (`not_yet_valid`, `expired`).
7. **Nonce** (`nonce_invalid`, `nonce_reused`). A nonce issued at or before the current
   authority's takeover is `unknown_user`.
8. **Authority by intersection.** A request for scope `s` is allowed iff
   `s ∈ scp ∩ policy(org, role(usr)) ∩ scopes-the-broker-serves`, with the role from the same
   roster evaluation as step 3 (`scope_denied`). A demotion therefore narrows every outstanding
   delegation at the next request, with no re-issue.
9. **Commit.** Bind the nonce first (the loser of a race writes nothing), then record the
   person's fresh ops and the roster evaluation.

A delegation is never revoked as an object. It stops verifying when the issuing device is
removed (or the managed key unenrolled), when the person is removed or demoted, when the org
re-roots, or after at most 24 hours. There is no `jti` denylist in v1.

The reference broker maps these words to HTTP: `malformed` and `wrong_type` → `400`; the proof,
signature, window, nonce, issuer and audience words → `401`; `unknown_user`, `scope_denied` and
`scope_exceeds_role` → `403`. The body is `{"error": "<word>"}`.

## The `webauthn` member key

**Status: stable.** Go core `identity` (verification only; Go mints no WebAuthn signatures).

A passkey member key is `webauthn:es256:<130 lowercase hex>`: the uncompressed P-256 point
`04‖X‖Y`, which MUST be a valid point other than the identity. It signs a body `B` under a
domain `D` through an ordinary WebAuthn `get()` ceremony whose challenge is derived from the
body:

```
challenge = SHA-256( "void-which-binds/webauthn/challenge/v1" ‖ 0x00 ‖ D ‖ 0x00 ‖ B )
```

passed as `PublicKeyCredentialRequestOptions.challenge` with `userVerification: "required"`.
Every body a passkey asserts over MUST contain a broker-issued 32-byte nonce for that ceremony
(the delegation's `non`, the approval challenge's nonce, the fetch nonce).

In place of an Ed25519 signature the token (or field) carries the base64url of an **envelope**
(`examples/webauthn-envelope.json`):

```json
{"ad": "<base64url authenticatorData>", "cd": "<base64url clientDataJSON>", "sig": "<base64url DER ECDSA signature>"}
```

The verifier picks the scheme from the **signer's key kind**, never from the shape of the
signature: an Ed25519 signer with an envelope, or a passkey with a bare 64-byte signature, is
`bad_signature`. It then checks, refusing with a distinct word:

| Check | Refusal |
| --- | --- |
| `cd` (a leading UTF-8 BOM stripped) parses as strict JSON with no duplicate keys; `type`, `challenge`, `origin` are strings; envelope at most 16 KiB with no duplicate keys | `malformed` |
| `type == "webauthn.get"` | `wrong_ceremony` |
| `challenge == base64url(challenge(D, B))` | `challenge_mismatch` |
| `origin` exactly equals an allowed origin; `crossOrigin` is not `true`; no `topOrigin` | `origin_not_allowed` |
| `authData[0:32] == SHA-256(rpId)` for the RP ID paired with that origin | `rp_id_mismatch` |
| UP (bit 0) set | `user_not_present` |
| UV (bit 2) set: always required | `user_not_verified` |
| BE = 0 implies BS = 0; AT (bit 6) clear; `authData` exactly 37 bytes unless ED (bit 7) is set | `malformed` |
| BE = 1 (synced passkey) only for an org-managed person | `synced_not_allowed` |
| ECDSA P-256/SHA-256 over `authData ‖ SHA-256(cd)`, strict DER, no trailing bytes | `bad_signature` |

`signCount` is ignored (verifiers are offline and keep no per-credential state). Attestation is
not verified. Where a flow reports only one word for a failed signature (delegation, approval),
every row above surfaces as `bad_signature` with the finer cause logged.

## Security considerations

- A capability grant's issuer is selected by the `iss` hint and proven by the signature; an
  unpinned issuer is refused before any field is read.
- A delegation lends at most what the person's role allows **at the time of each request**.
  Brokers MUST evaluate role and membership per request, not cache them per delegation.
- The proof binds the agent key to the request; a stolen delegation without the agent key is
  useless.
- Agent keys and member keys MUST stay disjoint, or an agent could approve or re-delegate.
