# The broker as an OpenID Provider

An organisation's broker is a minimal **OpenID Provider** for that one organisation, so that apps
it did not write (relying parties) can sign people in with their Void-Which-Binds member keys,
learn their roster role, and be told to end sessions when standing changes.

| Part | Status | Implemented by |
| --- | --- | --- |
| ID token, JWKS and key-pinning rules; RP verification | stable | Go core `oidc` (mint and verify); RP plugin `standard_id-void_which_binds` |
| Discovery document shape, PKCE S256, the `login` action and code binding | stable | Go core `oidc` |
| SET format, RP verification, RFC 8935 push answers, the RP's watermark rules | stable | Go core `secevent`; RP plugin `standard_id-void_which_binds` |
| The issuer's HTTP endpoints (authorize, token, JWKS, discovery) and the SET outbox | **draft** | accepted design (ADR-0023); not yet served by the reference broker |
| Back-channel approval (CIBA): assertion format, action builder, error words | stable primitives | Go core `oidc` |
| Back-channel approval endpoints and RP flow | **draft** | accepted design (ADR-0024); no broker serves it and no RP consumes it yet |

The **issuer** is the broker's public HTTPS origin, with no path and no trailing slash. One
broker serves one organisation.

## Profile

- Authorization code flow only: `response_type=code`, `response_mode=query`,
  `grant_type=authorization_code`. No implicit, hybrid, password, client-credentials or device
  flow; no refresh tokens, no userinfo, no logout endpoints, no dynamic registration, no PAR or
  request objects, public subjects only.
- **PKCE is required, `S256` only.** `plain`, a missing challenge, or a verifier outside 43–128
  characters is refused.
- **Clients** are confidential and registered statically by an org owner: `client_id`
  (`[a-z0-9][a-z0-9-]{0,63}`), display name, exact redirect URIs, a SET push endpoint, and the
  SHA-256 of a 32-byte client secret (two may be live, for rotation). Client authentication is
  **`client_secret_basic` only**.
- **No SSO session at the broker.** Every authorization runs a fresh approval ceremony.

## Login (draft endpoints)

### Authorization request

`GET <authorization_endpoint>` with `client_id`, `redirect_uri`, `scope` (MUST include
`openid`; `email` optional; anything else `invalid_scope`), `state`, `nonce`, `code_challenge`
and `code_challenge_method=S256`, all required. `request`/`request_uri` are
`request_not_supported`; `prompt=none` is `login_required`; other hints are ignored. An unknown
client or an unregistered redirect URI is shown on the broker's own error page and **never**
redirected.

The ceremony **is an action approval** ([approval.md](approval.md)) of:

```
Action{kind: "login", resource: "oidc:client/<client_id>",
       summary: "Sign in to <display name from the registry, never the request>",
       params: canonical JSON {"client_id","code_challenge","nonce","redirect_uri"}}
```

with approval `ttl = 0` (single use), `examples/oidc-login-action-params.json`. The resource
gates login per client by role: a role may sign in to a client only if the org policy grants it
`oidc:client/<client_id>`. Two approver paths are accepted:

| Path | Approver key | `amr` |
| --- | --- | --- |
| a passkey on the same device, discoverable and user-verified, RP ID = the broker's host | `webauthn:es256:` | `["mfa","pop","user"]` |
| a member device across devices (the person enters an email; the broker wakes their devices) | `ed25519:` | `["mca","pop"]` |

`amr` never claims `hwk` or `swk`. A delegation, a bare possession proof and the web-login
challenges of [weblogin.md](weblogin.md) are refused as login evidence: none of them names the
client or the PKCE challenge.

On approval the broker consumes the approval, then mints a **code**: 32 random bytes, single
use, valid 60 seconds, bound to the client, redirect URI, code challenge, nonce, person and
`auth_time`. The redirect carries `code`, `state` and `iss` (RFC 9207).

### Token request

`POST <token_endpoint>`, `client_secret_basic`, `grant_type=authorization_code`, `code`,
`redirect_uri`, `code_verifier`. The broker authenticates the client, checks the redirect URI
and verifier, burns the code, **re-evaluates the person's standing now**, and re-checks that the
current role still holds `oidc:client/<client_id>`. Any failure is `invalid_grant`. A second
redemption of a code is `invalid_grant` and also triggers a `session-revoked` SET for that
subject to that client. Success (`examples/oidc-token-response.json`), with
`Cache-Control: no-store`:

```json
{"id_token": "<jws>", "access_token": "<32 random bytes, base64url>", "token_type": "Bearer", "expires_in": 300}
```

The `access_token` exists only because OIDC Core requires one; **no endpoint accepts it**.
Errors are the RFC 6749 JSON shape (`examples/oidc-error.json`).

## The ID token

**Stable.** A compact JWS whose protected header is exactly
`{"alg":"EdDSA","kid":"<thumbprint>","typ":"JWT"}` (`examples/oidc-id-token-header.json`),
Ed25519 per RFC 8037.

| Claim | Req. | Value |
| --- | --- | --- |
| `iss` | yes | the issuer, byte-exact |
| `sub` | yes | the **person id**: `ed25519:<64 hex>` (sovereign) or `mp:<32 hex>` (managed). Never a device, passkey or enrolled key |
| `aud` | yes | the `client_id`, a single string (an array is refused) |
| `iat` | yes | issued at, stamped from the broker's monotonic clock |
| `exp` | yes | exactly `iat + 300` |
| `auth_time` | yes | when the approval was given; `≤ iat` |
| `nonce` | yes | echoed from the authorization request |
| `org` | yes | the org id, fixed across re-roots |
| `role` | yes | `viewer`, `member`, `admin` or `owner`, from the token-time evaluation |
| `amr` | yes | exactly `["mfa","pop","user"]` or `["mca","pop"]` |
| `email`, `email_verified` | together or not at all | only with the `email` scope and when the broker's directory has an address |

There are no other claims (`examples/oidc-id-token-claims.json`). `email_verified` is `true`
only when the person completed a link the broker sent to that address, or the address is in a
domain the organisation administers.

**The RP MUST**, in addition to the signature and pin checks below: require `typ == "JWT"` and
`alg == "EdDSA"`; require `iss`, `aud`, `org` equal to its configuration and `nonce` equal to
its own session's nonce (used once); refuse an `events` claim; require `exp == iat + 300` and
`auth_time ≤ iat`; require `amr` to be exactly one of the two arrays; accept only while
`exp > now − leeway` and `iat < now + leeway`, with `leeway ≤ 60 s`; check the redirect's
RFC 9207 `iss` **before** exchanging the code. It links accounts by `sub`, and by email only
when `email_verified` is `true`.

## Keys and pinning

**Stable.** ID tokens, SETs and approval assertions are signed with one broker signing key that
is never a roster member key, so its signatures can never stand as a roster op, cosignature or
delegation.

- The **JWKS** at `<issuer>/.well-known/jwks.json` lists RFC 8037 OKP keys
  `{"kty":"OKP","crv":"Ed25519","x","kid","use":"sig","alg":"EdDSA"}`
  (`examples/oidc-jwks.json`), where `kid` is the RFC 7638 SHA-256 thumbprint over
  `{"crv","kty","x"}`, base64url.
- **Pinning.** An RP holds a non-empty set of pinned thumbprints and verifies only under a key
  whose **recomputed** thumbprint is pinned and equals `kid`. A published key that is not pinned
  is ignored. The JWKS distributes keys; it is never a trust root. An RP MAY carry the JWKs
  inline.
- **Planned rotation.** The broker publishes the next key alongside the current one; each RP
  pins the next thumbprint; once every client has acknowledged, the broker switches; the old key
  stays published and pinned for 15 minutes after the switch, then leaves both.
- **Emergency rotation** means re-pinning at every RP out of band; logins fail until then.

## Discovery

**Stable shape; draft serving.** `<issuer>/.well-known/openid-configuration` holds exactly
(`examples/oidc-discovery.json`): `issuer`, `authorization_endpoint`, `token_endpoint`,
`jwks_uri`, `response_types_supported ["code"]`, `response_modes_supported ["query"]`,
`grant_types_supported ["authorization_code"]`, `subject_types_supported ["public"]`,
`id_token_signing_alg_values_supported ["EdDSA"]`,
`token_endpoint_auth_methods_supported ["client_secret_basic"]`,
`code_challenge_methods_supported ["S256"]`, `scopes_supported ["openid","email"]`,
`claims_supported` (the claim table above, in order) and
`authorization_response_iss_parameter_supported: true`. A broker with a back-channel client adds
`urn:openid:params:grant-type:ciba` to `grant_types_supported`, then
`backchannel_authentication_endpoint`, `backchannel_token_delivery_modes_supported ["poll"]`
and `backchannel_user_code_parameter_supported: false`. Every endpoint MUST be an HTTPS URL on
the issuer's own origin with no query or fragment.

The RP's own configuration is authoritative: a discovered `issuer` that differs from it is a
hard error.

## Deprovisioning: Security Event Tokens

**Stable format and RP rules; draft outbox.** When a person's standing changes, the broker
pushes one RFC 8417 SET per cause to every client it issued an ID token to for that `sub`.

Header exactly `{"alg":"EdDSA","kid":"<thumbprint>","typ":"secevent+jwt"}`
(`examples/set-header.json`). Claims (`examples/set-claims-session-revoked.json`,
`examples/set-claims-account-disabled.json`):

| Claim | Value |
| --- | --- |
| `iss` | the issuer |
| `aud` | one `client_id` (each client gets its own SET and `jti`) |
| `jti` | 16 random bytes, base64url |
| `iat` | when this SET was minted |
| `toe` | when the cause took effect at the broker; required; `≤ iat` |
| `txn` | groups the SETs one cause produced (a roster op hash or an internal cause id) |
| `sub_id` | `{"format":"iss_sub","iss":<issuer>,"sub":<the ID token's sub>}` |
| `events` | exactly one event |

There is no JWT `sub`, no `exp` and no `nonce`.

| Event | URI | Payload |
| --- | --- | --- |
| session revoked | `https://schemas.openid.net/secevent/caep/event-type/session-revoked` | `event_timestamp` (= `toe`), `initiating_entity` (`admin`, `user` or `policy`), `reason_admin: {"en": <cause>}` |
| account disabled | `https://schemas.openid.net/secevent/risc/event-type/account-disabled` | `{}` |

| Cause (`reason_admin`) | SETs sent |
| --- | --- |
| `roster_remove`, `role_expired` (`initiating_entity: policy`) | account-disabled, then session-revoked |
| `role_changed` | session-revoked |
| `key_removed` (a sovereign device remove or managed unenrol the broker records) | session-revoked |
| `code_replayed` | session-revoked, to that client only |
| `regenesis` (a sovereign person replaced by a new genesis) | account-disabled, then session-revoked, for the old `sub` |

A frozen org sends no SETs.

**Delivery** is RFC 8935 push: `POST` to the client's endpoint with
`Content-Type: application/secevent+jwt`, body the compact SET. The RP answers:

| Outcome | Answer | Broker action |
| --- | --- | --- |
| applied; duplicate `jti`; unknown subject; acknowledged without being applied | `202`, empty body | delivered |
| key, algorithm or signature refused (for example a pin gap during rotation) | `400 {"err":"invalid_key"}` | retry |
| wrong `iss` / `aud` | `400 {"err":"invalid_issuer"}` / `{"err":"invalid_audience"}` | retry |
| anything else wrong with the SET | `400 {"err":"invalid_request"}` | dead letter |
| a fault on the RP's side | `500` | retry |

The error body is RFC 8935's `{"err": <code>, "description"?: <text>}`
(`examples/set-push-error.json`). The broker retries `5xx`, `429`, network failures, any status
outside 202/400, and the retryable codes (`invalid_key`, `invalid_issuer`, `invalid_audience`,
`authentication_failed`, `access_denied`) with exponential backoff and full jitter from 10 s to
a 1 h cap for 72 h, then dead-letters; `invalid_request`, no code or an unknown code is
dead-lettered at once. A retry re-signs with the current key but never changes the claims.

**The RP MUST:**

1. Verify under a pinned thumbprint with `typ == "secevent+jwt"`; check `iss`, `aud` equal to its
   own `client_id`, and `sub_id` of format `iss_sub` with `sub_id.iss == iss`. Refuse a JWT `sub`,
   `exp` or `nonce`, more than one event, a missing `toe`, or `toe > iat`.
2. Refuse an `iat` more than 7 days old or more than 60 s in the future. Deduplicate `jti` for at
   least 7 days; a duplicate gets `202` and does nothing.
3. Apply by **watermark**, comparing only broker stamps (ID-token `iat` and SET `toe`, both from
   the broker's monotonic clock), with ties revoking:
   - **session-revoked** revokes every session (and its tokens) created from an ID token with
     `iat ≤ toe`, and raises a per-subject (`sub_id.iss`, `sub_id.sub`) revocation watermark to
     `toe`, never lowering it, even for a subject it has never seen. It refuses to create a
     session from any ID token with `iat ≤` that watermark.
   - **account-disabled** applies only if `toe ≥` the subject's newest login `iat`; it then
     revokes those sessions and disables the link at `toe`. A later login with `iat >` the
     disabled `toe` re-enables it.
4. Answer `202` only after those writes, the watermark included, are durable.

## Back-channel approval (CIBA)

**Draft endpoints; stable primitives.** An RP asks the broker to get one person to approve one
action on their device, and receives a signed **approval assertion**. It follows OpenID CIBA
Core 1.0 in **poll mode** only, with these departures: the request names an action, not scopes;
`login_hint` is the person id; the result is an approval assertion, not tokens. Only clients
whose registry entry carries `backchannel: true` may use it (`unauthorized_client` otherwise).

### Request

`POST /oidc/bc-authorize` (the discovered `backchannel_authentication_endpoint`), form-encoded,
`client_secret_basic`:

| Parameter | Value |
| --- | --- |
| `login_hint` | the person id (`ed25519:` or `mp:`), never an email or key. The broker must have issued an ID token for that person to this client |
| `kind` | `step-up` or `consent` |
| `binding_message` | 1–200 bytes of UTF-8 in **NFC** (refused, never normalised); no control (Cc), format (Cf), line or paragraph separator characters; no leading or trailing whitespace |
| `params` | a JSON object serialised with RFC 8785 (JCS), restricted to a **flat object of string values** whose member names match `[a-z][a-z0-9_]{0,31}` (consent's `scopes` is the one array of strings). The broker re-serialises and refuses any bytes that differ |

`login_hint_token`, `id_token_hint`, `user_code`, `request` and `client_notification_token` are
`invalid_request`; `requested_expiry`, `acr_values` and `scope` are not used.

For `consent`, `params` is exactly `{"client_id", "redirect_uri"?, "resource"?, "scopes"}`
(`examples/ciba-consent-params.json`): `client_id` is the OAuth client **at the RP's own
authorization server**; `scopes` is 1–32 sorted, de-duplicated scopes, each matching
`[a-z0-9._-]+(:[a-z0-9._-]+)*`; `redirect_uri` and `resource` are optional printable ASCII of at
most 2048 bytes. Each requested scope `s` is checked against the person's role policy as
`oidc:client/<requesting client_id>/<s with ':' replaced by '/'>` (the broker's client, not the
`client_id` inside `params`), so the same scope name at two RPs is two different policy scopes.

The broker builds the action
`{kind, resource: "oidc:client/<client_id>", summary: "<registry display name>: <binding_message>"
(consent: + " (scopes: s1, s2, …)"), params: the canonical bytes}`, creates a single-use
challenge and wakes **that person only**. It answers `200`, `Cache-Control: no-store`
(`examples/ciba-authorize-response.json`):

```json
{"auth_req_id": "<32 random bytes, base64url>", "expires_in": 120, "interval": 5,
 "match_number": 42, "summary": "<the composed summary>", "action_digest": "<base64url>"}
```

Errors: `unauthorized_client`, `unknown_user_id`, `access_denied` (the role lacks the resource
or a consent scope), `invalid_request`, `invalid_binding_message`, and `slow_down` (HTTP 429)
over a per-client or per-person rate limit.

### Polling

`POST /oidc/token`, `client_secret_basic`, `grant_type=urn:openid:params:grant-type:ciba`,
`auth_req_id`:

| Condition | Response |
| --- | --- |
| pending | `400 authorization_pending` |
| polled sooner than `interval` | `400 slow_down`, and that request's interval grows by 5 s |
| the 2-minute window closed without an approval | `400 expired_token` |
| approved by someone other than `sub`, or at redemption `sub` lacks standing, the role, or a consent scope | `400 access_denied` (terminal: the approval is consumed and the request dead) |
| unknown, another client's, already redeemed or denied | `400 invalid_grant` |
| approved by `sub` and every redemption check passes | `200 {"approval_assertion": "<jws>", "expires_in": 300}` (`examples/ciba-token-response.json`) |

### The approval assertion

Header exactly `{"alg":"EdDSA","kid":"<thumbprint>","typ":"vwb-approval+jwt"}`
(`examples/approval-assertion-header.json`), signed with the same pinned key as the ID token.
Claims (`examples/approval-assertion-claims.json`):

| Claim | Value |
| --- | --- |
| `iss` | the issuer |
| `sub` | the person asked about, who approved |
| `aud` | the requesting `client_id`, a single string |
| `org` | the org id |
| `iat`, `exp` | `exp − iat ≤ 300` (the broker mints exactly 300) |
| `auth_time` | when the approval was given |
| `amr` | exactly `["mfa","pop","user"]` or `["mca","pop"]` |
| `act_digest` | the action digest, base64url (43 characters) |
| `kind` | `step-up` or `consent` |
| `jti` | 16 random bytes, base64url |

No other claims (in particular no `nonce`, `events`, `sub_id`, `role`, `email` or `scope`).

### The RP's contract

1. Store `auth_req_id`, `kind`, `params`, `summary` and `action_digest` on the session. Check that
   `summary` ends with `": " + binding_message` (plus the scope suffix for consent), and
   **recompute** the digest from `(kind, "oidc:client/<own client_id>", summary, params)`; a
   mismatch abandons the request.
2. **Display `match_number`** and the summary on the screen that started the request until it
   ends. The broker never shows this number anywhere else.
3. Poll no faster than `interval`, honouring `slow_down`.
4. Verify the assertion: pinned key, `typ` and `alg` exact; `iss`, `aud`, `org` as configured;
   `sub` the person asked about; `kind` and `act_digest` as stored; `exp − iat ≤ 300`; the 60 s
   leeway rules of the ID token; `auth_time ≤ iat`; `amr` exactly one of the two arrays; no
   forbidden claim. An ID token or SET presented as an assertion (or the reverse) fails on `typ`.
5. Single use: keep `jti` until at least `exp + 60 s` and refuse a repeat.
6. Refuse the assertion if `iat ≤` the subject's revocation watermark, the link is disabled, or
   the session that started the request has been revoked since.

Step-up freshness (`max_age`, default 5 minutes, bound to the digest) is the RP's policy, not the
broker's.

## Security considerations

- Every login and back-channel approval needs a live member's approval on a device, an exact
  registered redirect URI (login) and the PKCE verifier, so a stolen client secret alone yields
  nothing.
- The token endpoint re-evaluates standing, so an ID token stamped after a removal exists only if
  the person was re-added; together with the watermark, a delayed or replayed SET cannot undo a
  later re-add.
- Pinning means a compromised host serving a new JWKS cannot mint accepted tokens.
- `email_verified` is trustworthy for account linking **only** because the broker is the
  organisation's own; an RP MUST NOT extend the same linking trust to a multi-tenant provider.

## Code and documentation notes

- ADR-0023 states the RP's time checks as "`exp > now − 60 s`, `iat < now + 60 s`". The Go
  verifier takes a configurable leeway of at most 60 s and additionally requires
  `exp == iat + 300` and `auth_time ≤ iat`.
- The authorization and token endpoint paths are not fixed; they come from discovery. The Go
  core's tests and ADR-0024 use `/oidc/authorize`, `/oidc/token` and `/oidc/bc-authorize`, and the
  examples follow them.
