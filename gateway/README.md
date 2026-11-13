# Gateway

The credential gateway sits between an agent and the services it calls: model providers, git hosts
and MCP/HTTP connectors. The caller holds only a short-lived token. The gateway checks that token,
looks up what it may reach, swaps in the real credential and forwards the request. The caller never
holds the real secret.

This document is the contract around the gateway: what a caller sends it, how it asks a
coordinator what a run token may reach, which identity providers it trusts, where it reads
secrets from, how it refuses, and what it records.

| Section | Status |
| --- | --- |
| [1. Overview](#1-overview) | stable |
| [2. Caller interface](#2-caller-interface) | stable |
| [3. Token routing](#3-token-routing) | stable |
| [4. Run-token resolver](#4-run-token-resolver) | stable |
| [5. Static grants file](#5-static-grants-file) | stable (tests and development only) |
| [6. Trusted issuers](#6-trusted-issuers) | stable |
| [7. Permissions](#7-permissions) | stable |
| [8. Credential-source file](#8-credential-source-file) | stable |
| [9. What the gateway enforces on the way out](#9-what-the-gateway-enforces-on-the-way-out) | stable |
| [10. Errors and refusals](#10-errors-and-refusals) | stable |
| [11. Audit records](#11-audit-records) | stable |
| [12. Security considerations](#12-security-considerations) | stable |
| [13. Policy by reference](#13-draft-policy-by-reference) | **DRAFT** |
| [14. Notes on the implementation](#14-notes-on-the-implementation) | informative |

"Stable" means implemented and relied on; changes are versioned. "Draft" means proposed and not
implemented; it may change without a version bump. MUST, SHOULD and MAY are as in RFC 2119.

## 1. Overview

*Status: stable.*

### Parties

| Party | Role |
| --- | --- |
| **Caller** | Anything that calls a model API, a git host or a connector through the gateway: a harness inside a run sandbox, a person's own agent, a chat front door, a CI job. It holds a *run token* or a *trusted issuer's access token*, never the real credential. |
| **Gateway** | Authenticates the caller, decides what the request may reach, injects the real credential and forwards. It holds secrets in memory only. |
| **Coordinator** | Mints run tokens and answers the gateway's *resolve* call for them (section 4). The Jumpdrive control plane is one coordinator; any service that implements section 4 is another. |
| **Trusted issuer** | An OAuth 2.0 authorization server whose signed JWT access tokens the gateway accepts directly (section 6). |
| **Credential source** | Where the gateway reads secrets for a trusted issuer's principals: a file today (section 8). |
| **Upstream** | The provider, git host or connector the request is finally sent to. |

### Transport

- Callers reach the gateway over HTTP/1.1 or HTTP/2. In any deployment beyond a single machine,
  the gateway MUST be fronted by TLS; it has no notion of its own public URL and does not trust
  `X-Forwarded-*` or `Forwarded` (it drops them).
- The gateway reaches the coordinator, issuers and upstreams over HTTPS. Plain `http` is accepted
  only for a loopback host, for development.
- Request headers are limited to 64 KiB. Header read time is limited to 10 s. There is no read or
  write timeout on bodies, because model streams and clones run for minutes. An upstream must
  start its response within 10 minutes.

### Authentication

- **Caller → gateway:** a run token or a trusted issuer's JWT access token, presented as an API
  key, a bearer token or a basic-auth password (section 2.2).
- **Gateway → coordinator:** a shared service secret per gateway deployment, as a bearer token
  (section 4.1).
- **Gateway → issuer:** none for JWKS; HTTP Basic with a confidential client for introspection
  (section 6.4).
- **Gateway → upstream:** the real credential, injected (section 9.2).

### Versioning

- **Resolver contract:** versioned by **path**: `/internal/gateway/v1/resolve`. There is no
  version member in the body. A gateway that speaks v1 calls only the v1 path. An incompatible
  change gets a new path (`/v2/`); compatible additions (new optional members) do not. The
  gateway ignores members it does not know in a resolution, so a coordinator MAY add members.
- **Configuration files** (sections 5, 6, 8) carry no version member. The trusted-issuer and
  credential-source files are parsed strictly: an unknown member is a start-up error, not a
  warning. A future incompatible file shape will add a top-level `version` member; a gateway that
  does not know that version MUST refuse to start.
- **Caller routes** (section 2) are unversioned. Provider routes pass the provider's own path and
  version through (`/p/openai/v1/...`).
- **Draft messages** (section 13) carry `"version": 1`. A receiver that does not know the version
  MUST NOT act on the message (section 13.6).

## 2. Caller interface

*Status: stable.*

### 2.1 Routes

| Route | Upstream | Credential injected |
| --- | --- | --- |
| `/p/{provider}/{path}` | the provider's API with `{path}` appended (table below) | Anthropic: `X-Api-Key: <key>`. OpenAI, OpenRouter: `Authorization: Bearer <key>`. |
| `/git/{host}/{owner}/{repo}/{path}` | `https://{host}/{owner}/{repo}/{path}` | `Authorization: Basic base64(username:password)` |
| `/c/{connector_id}` and `/c/{connector_id}/{path}` | the connector grant's `url` with `/{path}` appended and both query strings joined | `Authorization: Bearer <token>` by default, or as the grant's `header`/`scheme` say (section 4.3) |
| `GET /healthz` (also `HEAD`) | none | none. Answers `200` with body `ok\n`. No token is needed and no audit record is written. |

| `{provider}` | Upstream base | Harness configuration |
| --- | --- | --- |
| `anthropic` | `https://api.anthropic.com` | base URL `{gateway}/p/anthropic`, API key = the token |
| `openai` | `https://api.openai.com` | base URL `{gateway}/p/openai/v1`, API key = the token |
| `openrouter` | `https://openrouter.ai/api` | base URL `{gateway}/p/openrouter/v1`, API key = the token |

- A `{provider}` the gateway does not know gets `404 not_found_error`.
- A connector id is matched exactly (case-sensitive). A git host, owner and repo are matched
  case-insensitively, and a trailing `.git` on the repo is ignored.
- For git, use `{gateway}/git/{host}/{owner}/{repo}.git` as the clone URL, with the token as the
  basic-auth password or as `http.extraHeader=Authorization: Bearer <token>`.
- For an MCP connector, use `{gateway}/c/{connector_id}` as the server URL, with
  `Authorization: Bearer <token>`.

A path that matches no route gets the HTTP server's own plain-text answer (`404`, `405`, or a
`301` that adds a trailing slash, for `/p/{provider}` and `/git/{host}/{owner}/{repo}` with
nothing after them). Those answers do not use the error envelope and produce no audit record.

### 2.2 Presenting the token

The gateway reads the caller's token from any of:

1. the `X-Api-Key` header;
2. `Authorization: Bearer <token>`;
3. the password of `Authorization: Basic base64(user:password)`. The username is ignored.

Rules:

- Surrounding whitespace is trimmed. Other `Authorization` schemes are ignored.
- The same value presented in two places is one credential. **Two different values** are refused
  with `401 authentication_error`; the gateway never guesses which one was meant.
- No token at all gets `401 authentication_error`.
- On the git route, every `401` also carries `WWW-Authenticate: Basic realm="jumpdrive-gateway"`,
  so `git` prompts for or retries with credentials.

A caller SHOULD send the token only to the gateway. A harness that ignores the gateway's base URL
and calls a vendor directly holds only the placeholder token, so the call fails to authenticate.

## 3. Token routing

*Status: stable.*

The gateway accepts two kinds of token and decides which kind it holds **before** checking it.
The decision is deterministic, and a token never falls through from one kind to the other.

1. If the token is at most 16 KiB, parses as a compact JWS (three non-empty base64url parts whose
   header and payload are JSON objects, with a string `alg`), and its **unverified** `iss` claim
   names a configured trusted issuer exactly, it takes the **JWT path** (section 6) and only
   that path. Any failure there is `401` or `503`. The token is never sent to the coordinator.
2. Everything else is a **run token** and goes to the run-token resolver (section 4): opaque
   tokens, JWTs from issuers not configured, JWTs larger than 16 KiB, and anything that is not a
   JWS.

With no trusted issuers configured, every token is a run token.

A coordinator MUST NOT mint run tokens that parse as a compact JWS whose `iss` could name a
trusted issuer, because such a token would be routed to the JWT path and refused there.

## 4. Run-token resolver

*Status: stable.*

The gateway does not parse or verify run tokens. It asks the coordinator, then caches the answer
briefly (section 4.5). Run tokens are opaque to the gateway; their format is the coordinator's
choice (section 14 describes the reference coordinator's).

### 4.1 Request

```
POST {coordinator_origin}/internal/gateway/v1/resolve
Authorization: Bearer <gateway service secret>
Content-Type: application/json
Accept: application/json

{"token": "<run token as the caller presented it>"}
```

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `token` | string | yes | The token exactly as extracted from the caller's request (section 2.2), after trimming. |

- The service secret authenticates **the gateway**, not the caller. The coordinator MUST compare
  it in constant time and MUST refuse every request when it has no secret configured.
- The gateway times out after 5 s.
- Example: [`examples/resolve-request.json`](examples/resolve-request.json).

### 4.2 Response status

| Status | Meaning | The gateway answers the caller |
| --- | --- | --- |
| `200` | a resolution (section 4.3) | proceeds to the grant checks |
| `404` | unknown, revoked, malformed or (see below) expired token | `401` |
| `409` | the token's attempt is no longer the run's live attempt, or the run is finished, parked or can no longer run | `401` |
| `410` | the token has expired | `401` |
| `401` or `403` | **the gateway's service secret** is wrong or missing | `503`, logged as an error |
| anything else, a network error or a timeout | resolver unavailable | `503` |

- `401` and `403` are reserved for the gateway's own credential. A coordinator MUST NOT use them
  for a bad run token, so that a misconfigured gateway (an alert) is never confused with a bad
  caller (routine).
- A coordinator that cannot tell an expired token from a forged one SHOULD answer `404`; the
  gateway's answer to the caller is the same.
- A rate-limited coordinator's `429` is "anything else": the caller gets `503`.
- The body of a non-`200` answer is ignored. The reference coordinator sends
  `{"error": "<reason>"}` ([`examples/resolver-refusal.json`](examples/resolver-refusal.json)).
- The coordinator SHOULD send `Cache-Control: no-store` on every answer.

### 4.3 The resolution (200 body)

One JSON object, at most 1 MiB. Credential values are plaintext in this body: it MUST travel only
over the authenticated internal hop, and neither side may log or store it.

Example with every member present: [`examples/resolution.json`](examples/resolution.json).

**Top level**

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `run_id` | string | yes, non-empty | The run the token belongs to. Scopes attempt binding and the token budget. |
| `attempt` | integer | yes, ≥ 1 | The attempt the token is bound to. |
| `current_attempt` | integer | no | The run's live attempt when the coordinator answered. Absent or `0` means "same as `attempt`". Any other value that differs from `attempt` is treated like a `409`. |
| `expires_at` | string, RFC 3339 | yes | When the token stops working. A past or missing `expires_at` is refused (`401`) even on a `200`. |
| `grants` | object | yes (MAY be `{}`) | What the token may reach. Anything not granted is refused. |
| `budget` | object | no | A model-token budget for the attempt. |

A resolution with an empty `run_id` or an `attempt` below 1 is treated as an unknown token
(`401`). A body that is not valid JSON, or exceeds 1 MiB, is treated as an unavailable resolver
(`503`).

**`grants`**

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `providers` | object: provider name → provider grant | no | Model providers the token may call. Keys are `anthropic`, `openai`, `openrouter`; other keys are ignored. |
| `models` | array of strings | no | Model allowlist across all providers. Absent or empty: any model. An entry ending in `*` matches by prefix (`example-model-small-*`); every other entry matches exactly (case-sensitive). |
| `git` | array of git grants | no | Repositories the token may clone, fetch and (with `write`) push. |
| `connectors` | array of connector grants | no | MCP/HTTP connectors the token may call. |

**Provider grant**

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `key` | string | yes, non-empty | The provider API key. A grant with an empty key is treated as not granted. |
| `credential_layer` | string | no | The layer the key came from: `user`, `workspace`, `org` or `platform`. Copied into audit records. |

**Git grant**

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `host` | string | yes | Git host, as in the route (`git.example.com`). Matched case-insensitively. |
| `owner` | string | yes | Repository owner. Matched case-insensitively. |
| `repo` | string | yes | Repository name. Matched case-insensitively; a trailing `.git` on either side is ignored. |
| `write` | boolean | no, default `false` | Allows push (`git-receive-pack`). |
| `username` | string | no, default `x-access-token` | Basic-auth username sent upstream. |
| `password` | string | yes (MAY be empty) | Basic-auth password sent upstream. Empty means a public repository: no `Authorization` header is sent upstream. |
| `credential_layer` | string | no | As for a provider grant. |

If several git grants match a request, the first one in the array is used.

**Connector grant**

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | The `{connector_id}` in `/c/{connector_id}`. |
| `url` | string | yes | The real upstream endpoint. MUST be `https` with a host and no userinfo; otherwise the request is refused (`403`, "connector is misconfigured"). A query string in it is kept, with the caller's query appended. |
| `header` | string | no, default `Authorization` | The header the credential is set in. |
| `scheme` | string | no | The value prefix, joined to the token with one space. When `header` is absent: `scheme` absent means `Bearer`, and `"-"` means the bare token. When `header` is present (even as `Authorization`): `scheme` absent, `""` or `"-"` means the bare token (an `X-Api-Key` style header). |
| `token` | string | yes (MAY be empty) | The credential. Empty means no credential header is sent upstream. |
| `credential_layer` | string | no | As for a provider grant. |

If several connector grants share an `id`, the first one is used.

**`budget`**

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `max_tokens` | integer | no | Model-token cap for the attempt. Absent, `0` or negative: uncapped. |
| `used_tokens` | integer | no | Tokens the coordinator has already recorded for the attempt (for example from earlier audit records). Lets several gateways, or a restarted one, share one budget. |

How the gateway enforces the budget is in section 9.4.

### 4.4 Credential layers

`credential_layer` names which layer of credentials paid for a request, in resolution order:
`user` (the person's own), `workspace`, `org`, `platform` (the coordinator operator's). The
coordinator picks the layer; the gateway only reports it. Unknown values are copied through.

### 4.5 Caching and attempt binding

- **TTL.** A `200` answer is reused for a configurable TTL: 15 s by default, at most 5 minutes,
  and never past the resolution's `expires_at`. Changes the coordinator makes (revocation, OAuth
  refresh, budget top-up) therefore reach a running attempt within one TTL.
- **Keys.** Entries are keyed by the SHA-256 of the token. Raw tokens are not held as keys.
- **No negative caching.** Every refusal is asked again next time.
- **Attempt binding.** The gateway remembers the highest `attempt` it has seen for each `run_id`.
  Once any token for attempt *N* has resolved, a token for an attempt below *N* is refused
  (`401`), even if it is still cached or a stale coordinator answer calls it live.
- **Invalidation.** An upstream `401` on a provider or connector route drops the token's cached
  entry, so the next request re-resolves and picks up a credential the coordinator has refreshed.

### 4.6 What a coordinator must do

- Mint a distinct token per run **attempt**, bound to that attempt, with its own purpose so it
  cannot be used as any other token the coordinator issues.
- Answer `409` once the attempt is superseded or the run has stopped executing, and `404` (or
  `410`) once the token has expired or been revoked.
- Grant nothing the run would not have been given directly: the same model, providers,
  repositories and connectors.
- Never log the token or the body.

## 5. Static grants file

*Status: stable. For tests and local development only.*

With `GATEWAY_RESOLVER=static` the gateway resolves run tokens from a file instead of a
coordinator, and logs a warning at start-up.

- The file is one JSON object mapping **token → resolution**. Each value has exactly the shape of
  section 4.3, and is validated the same way on every use (expiry, `current_attempt`, `run_id`,
  `attempt`).
- Unknown members inside a resolution are ignored. A file that is not such an object refuses
  start-up.
- An unknown token is `401`. Caching and attempt binding (section 4.5) apply as for a coordinator.
- Example: [`examples/static-grants.json`](examples/static-grants.json).

## 6. Trusted issuers

*Status: stable.*

The gateway accepts signed JWT access tokens from configured OAuth 2.0 issuers. Any issuer that
meets this section works; the `standard_id` engine is one. Trusted issuers are off unless a
trusted-issuers file is configured.

A JWT request goes through three steps, then the same proxy as a run token:

1. **Authenticate:** verify the token and name its principal, `(iss, sub)` (sections 6.2 to 6.4).
2. **Credential source:** look up the grants and secrets for that principal (section 8).
3. **Policy:** if the issuer has `require_permissions: true`, drop every grant the token's
   `permissions` do not cover (section 7). Policy only narrows; it never adds or widens a grant.

### 6.1 Trusted-issuers file

One JSON object. Example: [`examples/trusted-issuers.json`](examples/trusted-issuers.json).

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `issuers` | array of issuer objects | yes, non-empty | The issuers to trust. |

**Issuer object**

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `issuer` | string | yes | The exact `iss` value. Each issuer may appear once. |
| `jwks_url` | string, URL | yes | The issuer's JSON Web Key Set. |
| `audience` | string | yes | The audience the gateway accepts; a token's `aud` must contain it. |
| `introspection` | object | no | RFC 7662 introspection, checked on every request (section 6.4). |
| `introspection.url` | string, URL | yes, if `introspection` | The introspection endpoint. |
| `introspection.client_id` | string | yes, if `introspection` | The gateway's confidential client id at the issuer. |
| `introspection.client_secret_file` | string, path | yes, if `introspection` | A file holding the client secret. Surrounding whitespace is trimmed; an empty file refuses start-up. |
| `introspection.cache_ttl` | string, Go duration | no, default `60s` | How long an active answer is reused. Must be in (0, `5m`]. |
| `require_permissions` | boolean | yes, set explicitly | `true`: grants are narrowed by the token's `permissions` (section 7). `false`: a verified principal gets every grant its credential source supplies. |
| `credentials.file` | string, path | yes | The credential-source file for this issuer's principals (section 8). Several issuers may name the same file. |

Every URL MUST be absolute, without userinfo, and `https`; `http` is allowed only to `localhost`
or a loopback address. The gateway reads this file, every secret file and every credentials file
at start-up and **refuses to start** on any problem: an unknown member, a duplicate issuer, a
missing or empty secret, a bad URL or TTL. Secrets are not reloaded; rotating one means
restarting the gateway.

### 6.2 Token requirements

**Header** (example: [`examples/jwt-header.json`](examples/jwt-header.json))

| Member | Requirement |
| --- | --- |
| `alg` | `ES256` or `RS256`. Everything else is refused before any key is looked at: `none`, every HMAC algorithm, `PS256`, `ES384` and so on. |
| `kid` | Required. Selects the key in the issuer's JWKS. |
| `typ` | Optional. If present, one of `JWT`, `at+jwt` or `application/at+jwt`, compared case-insensitively. |
| `crit` | Must be absent. A token with a `crit` header is refused. |

Header members are read by exact name: `ALG` is not `alg`.

**Claims** (example: [`examples/jwt-claims.json`](examples/jwt-claims.json))

| Claim | Type | Required | Check |
| --- | --- | --- | --- |
| `iss` | string | yes | Equal to the configured `issuer`. |
| `aud` | string or array of strings | yes | Equal to, or containing, the configured `audience`. |
| `exp` | NumericDate | yes | `now < exp + 30 s`. |
| `nbf` | NumericDate | no | `nbf ≤ now + 30 s`. |
| `iat` | NumericDate | no | `iat ≤ now + 30 s`. |
| `sub` | string | yes, non-empty | The principal's subject. Keys the user layer of the credential source. |
| `permissions` | array of non-empty strings | no | Read when the issuer has `require_permissions: true` (section 7). `null` counts as absent. |
| `client_id` | string | no | The OAuth client the token was issued to. Recorded in audit records. |
| `jti` | string | no | Token id. Scopes a per-token budget. Without it, the gateway uses `sha256:` plus the first 16 bytes of the token's SHA-256, in hex. |

A NumericDate may be fractional and must be between 0 and 10<sup>11</sup>. A claim present with
the wrong type is refused. Claims are checked before the signature only to refuse sooner; a token
is accepted only when both pass.

### 6.3 Keys (JWKS)

- The gateway fetches `jwks_url` with `GET` (5 s timeout, at most 1 MiB) and reads the `keys`
  array. Example: [`examples/jwks.json`](examples/jwks.json).
- **Usable keys:** a non-empty `kid`; `use` absent or `sig`; `key_ops` absent or containing
  `verify`; and either
  - `kty: EC`, `crv: P-256`, 32-byte `x` and `y`, `alg` absent or `ES256`; or
  - `kty: RSA`, a modulus of at least 2048 bits, an odd exponent of at least 3 (at most 4 bytes),
    `alg` absent or `RS256`.

  Other keys are skipped. For a duplicate `(kid, alg)` the first key wins. A key set with no
  usable key counts as a failed fetch.
- A token's `alg` must equal the selected key's algorithm. An EC key never verifies `RS256`,
  and vice versa.
- ES256 signatures are the raw 64-byte `r || s` (RFC 7518), not ASN.1.
- **Freshness.** A fetched key set is reused for 24 h. An unknown `kid`, or a failed fetch, causes
  at most one fetch per 30 s. While fresh keys exist, a `kid` they do not hold is a `401`. With no
  fresh key set (the issuer down on first use, or after 24 h) the gateway fails closed with
  `503`.
- An issuer rotating keys SHOULD publish the new key before signing with it.

### 6.4 Introspection (optional)

When configured, the gateway asks the issuer whether the token is still active **on every
request**, after the signature checks out, unless it holds a cached active answer.

```
POST {introspection.url}
Authorization: Basic base64(urlencode(client_id) ":" urlencode(client_secret))
Content-Type: application/x-www-form-urlencoded
Accept: application/json

token=<access token>&token_type_hint=access_token
```

- The client id and secret are form-encoded before being joined (RFC 6749 section 2.3.1).
- **Answer** (example: [`examples/introspection-response.json`](examples/introspection-response.json)):
  `200` with a JSON object of at most 64 KiB. The token is active only if `active` is the boolean
  `true`, and `sub` and `iss`, when present, equal the token's. Anything else is **inactive**
  (`401`).
- A non-`200` status, a malformed body, a network error or a 5 s timeout is **unavailable**
  (`503`).
- An active answer is cached for `cache_ttl`, never past the token's `exp`. Inactive answers are
  not cached. An upstream `401` on a provider or connector route drops the token's cached answer.
- Many issuers answer `active: false` when the gateway's own client credentials are wrong. A
  misconfigured client secret therefore shows up as every token getting `401`, not as `503`.

### 6.5 What a principal resolves to

A verified token becomes a resolution with a *caller* instead of a run: kind `jwt`, issuer,
subject, client id, token id. It carries no `run_id` or `attempt`, and run-token attempt binding
does not apply to it.

- It lasts until the token's `exp` plus 30 s.
- A coordinator can never answer with a principal: the caller is never read from a resolution's
  JSON.
- **Budget.** The credential source's `budget.max_tokens` caps **one access token**, counted by
  one gateway process. `used_tokens` is always 0. Nothing is reported to the issuer, and nothing
  is shared across a subject's tokens or across gateway instances.

## 7. Permissions

*Status: stable.*

When the issuer has `require_permissions: true`, each grant from the credential source survives
only if a string in the token's `permissions` claim allows it. A token with no `permissions` keeps
no provider, git or connector grant.

| Permission | Allows |
| --- | --- |
| `gateway:provider:<name>` | the `/p/<name>` provider grant (`anthropic`, `openai`, `openrouter`) |
| `gateway:git:<host>/<owner>/<repo>` | clone and fetch that repository |
| `gateway:git:<host>/<owner>/<repo>:write` | clone, fetch and push that repository |
| `gateway:connector:<id>` | the `/c/<id>` connector grant |

Matching:

- **Exact by default.** Provider and connector permissions are compared case-sensitively. Git
  permissions are compared case-insensitively, and a trailing `.git` on the repository is
  ignored.
- **Wildcards.** A permission ending in `*` matches every name it is a **prefix** of (not a glob):
  `gateway:provider:*`, `gateway:git:git.example.com/acme/*`, or `gateway:*` for every grant.
- **Push.** Only a permission ending in `:write` allows push. The part before `:write` may itself
  end in `*` (`gateway:git:git.example.com/acme/*:write`). A wildcard without `:write`, including
  `gateway:*`, never allows push.
- **Never widened.** A `:write` permission never makes a grant writable whose credential source
  entry has `write: false`. It does imply fetch.
- **Not governed by permissions:** the model allowlist and the budget. They come from the
  credential source unchanged.

## 8. Credential-source file

*Status: stable.*

Where a trusted issuer's principals get their grants and secrets. One file can serve several
issuers. Example with every member present: [`examples/credentials.json`](examples/credentials.json).

```
{ "issuers": { "<iss>": { "org": <layer>, "subjects": { "<sub>": <layer>, ... } } } }
```

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `issuers` | object: issuer → issuer entry | yes | Keys are exact `iss` values and must be non-empty. |
| `issuers.<iss>.org` | layer | no | The issuer-wide layer, reported as `credential_layer: "org"`. |
| `issuers.<iss>.subjects` | object: `sub` → layer | no | Each principal's own layer, keyed by the token's `sub`, reported as `credential_layer: "user"`. Keys must be non-empty and values non-null. |

**Layer**

| Member | Type | Meaning |
| --- | --- | --- |
| `providers` | object: provider name → `{ "key_file": path }` | Provider grants. `key_file` is required. |
| `models` | array of strings | The model allowlist, as in section 4.3. |
| `git` | array of `{ host, owner, repo, write, username, password_file }` | Git grants. `host`, `owner`, `repo` and `password_file` are required; `write` and `username` are as in section 4.3. A repository may appear once per layer. |
| `connectors` | array of `{ id, url, header, scheme, token_file }` | Connector grants. `id`, `url` (https, no userinfo) and `token_file` are required; `header` and `scheme` are as in section 4.3. An id may appear once per layer. |
| `budget` | `{ "max_tokens": integer ≥ 0 }` | A per-token cap (section 6.5). `0` is uncapped. |

Rules:

- **Secrets live in their own files**, named by `*_file` members. Surrounding whitespace is
  trimmed; a missing or empty file refuses start-up. An inline secret is an unknown member and
  refuses start-up, as does any other unknown member.
- **Most specific layer wins, per grant name, never merged.** A grant name is a provider name, a
  repository (`host/owner/repo`, case-insensitive, `.git` ignored) or a connector id; `models` and
  `budget` each count as one grant. A subject's entry for a repository replaces the org's entry
  whole, including `write` and `username`.
- **Unknown principals.** A verified principal with no `subjects` entry, under an issuer with no
  `org` layer, or an issuer absent from the file, has no grants: every route answers `403`.
- Then permissions narrow the result (section 7).

## 9. What the gateway enforces on the way out

*Status: stable.* These rules apply to run tokens and JWTs alike.

### 9.1 Order of checks

For every request: identify the route; authenticate (sections 3, 4, 6); check the grant; check the
request; strip; inject; forward; audit. Nothing is forwarded until every check passes.

- **Provider route:** known provider → token → provider granted (non-empty key) → endpoint on the
  allowlist, no `Upgrade` header, no dot segments → no compressed body → body readable (≤ 32 MiB)
  and strictly valid → every named model allowed → (inference) budget admits it.
- **Git route:** a smart-HTTP operation → token → repository granted → push only with `write` →
  body ≤ 1 GiB (streamed).
- **Connector route:** token → connector granted → usable `url` → no dot segments → body ≤ 16 MiB
  (streamed).

### 9.2 Stripping and injection

Before forwarding, the gateway removes from the outbound request:

- `Authorization`, `Proxy-Authorization`, `X-Api-Key`, `Api-Key`, `X-Goog-Api-Key`, `Cookie`,
  `OpenAI-Organization` and `OpenAI-Project`;
- any other header whose value contains the caller's token;
- any query parameter whose value contains the caller's token;
- `X-Forwarded-*` and `Forwarded`;
- on provider routes, `Accept-Encoding` (the gateway negotiates compression itself so it can read
  usage).

It then **sets** the grant's credential header, overwriting anything present. A request that
reaches the outbound transport without a resolved credential is never sent.

### 9.3 Provider endpoints and bodies

Only these method and path pairs are forwarded. Paths are matched on the escaped path below
`/p/{provider}`, so `%2F` tricks never match. Anything else is `403 permission_error`.

| Provider | Endpoint | Inference | Output-cap field |
| --- | --- | --- | --- |
| `anthropic` | `POST /v1/messages` | yes | `max_tokens` |
| `anthropic` | `POST /v1/messages/count_tokens`, `GET /v1/models`, `GET /v1/models/{id}` | no | |
| `openai` | `POST /v1/chat/completions` | yes | `max_completion_tokens` |
| `openai` | `POST /v1/completions` | yes | `max_tokens` |
| `openai`, `openrouter` | `POST /v1/responses` | yes | `max_output_tokens` |
| `openai`, `openrouter` | `POST /v1/embeddings` | yes | (none: input only) |
| `openai`, `openrouter` | `GET /v1/models`, `GET /v1/models/{id}` | no | |
| `openrouter` | `POST /v1/chat/completions`, `POST /v1/completions` | yes | `max_tokens` |

Websocket upgrades are refused. A request body, if any, MUST be a UTF-8 JSON object that a strict
parser accepts: no BOM, no UTF-16, no `NaN`, no second value, no top-level array. Otherwise `400`.
`Content-Encoding` other than `identity` is `415`.

Body keys are matched **exactly** (case-sensitive), as providers read them. The gateway reads:

- `model` (string; repeated or non-string is `400`);
- `models` (array of strings, an OpenRouter-style fallback list; each entry is checked);
- any `?model=` query parameter;
- `stream`, `n`, `best_of`, `prompt`, `max_tokens`, `max_completion_tokens`, `max_output_tokens`.
  A repeated key is `400`. `n` and `best_of` must be positive integers (or `null`). A `prompt`
  array that mixes token ids with prompts is `400`.

Every model named must be on the allowlist, else `403`. When the allowlist is non-empty, an
inference request that names no model is `403`.

The gateway **rewrites** a provider body in two cases only:

- an OpenAI-style streaming chat or completions request (`"stream": true` on those endpoints)
  gets `stream_options.include_usage: true`, keeping any other `stream_options`;
- under a budget, an inference request that names no output cap gets one, written into the
  endpoint's output-cap field (section 9.4).

Otherwise the body is forwarded byte for byte.

### 9.4 Budget

Applies to inference endpoints when `budget.max_tokens` is positive. It is scoped per
`(run_id, attempt)` for a run token, and per access token for a JWT.

- **Counting.** Tokens are read from each response's `usage`: the JSON body, or every SSE `data:`
  event of a stream. Figures are cumulative per response, so the maximum is kept.
- **Spent** is `max(used_tokens, baseline + charged here)`, where *baseline* is `used_tokens` when
  this gateway first saw the scope.
- **Reservation.** Before forwarding, the gateway reserves: input at about one token per 4 bytes
  of body, plus the request's output cap times every completion it can generate (`n`, or
  `best_of` when larger, per prompt). A request with no cap is given one: 16384, shrunk to what
  the budget has left after its input, and written into the forwarded body.
- **Admission.** A request is forwarded only while `spent + reserved in flight + its reservation ≤
  max_tokens`. Otherwise:
  - `402` if the budget is spent, or the request's own cap can never fit what is left;
  - `429` with `Retry-After: 1` if it would fit once in-flight requests settle.
- **Settlement.** When the request finishes, its reservation is released and it is charged:
  - the provider's reported usage, if the response was read to its end, reported usage and (for
    a stream) delivered its terminal event (`[DONE]`, `message_stop`, `response.completed`,
    `response.incomplete` or `response.failed`);
  - otherwise, for a `2xx` or for a request that reached the provider but got no response, the
    reservation estimate, marked `tokens_estimated` in the audit record;
  - for a non-`2xx`, its reported usage (usually none).

### 9.5 Git

Only smart HTTP is proxied. Anything else is `404 not_found_error`.

| Request | Operation |
| --- | --- |
| `GET`/`HEAD .../info/refs?service=git-upload-pack` | fetch discovery |
| `GET`/`HEAD .../info/refs?service=git-receive-pack` | push discovery (needs `write`) |
| `POST .../git-upload-pack` | fetch |
| `POST .../git-receive-pack` | push (needs `write`) |

Dumb HTTP and LFS are not supported. The upstream host comes from the route and must match a
grant, so an ungranted host is never dialled.

### 9.6 Egress guard (git and connectors)

Git and connector upstreams are dialled through a guard on the **resolved** address, which also
defeats DNS rebinding. A dial to any of these is refused with `403 permission_error`:
the three RFC 1918 private blocks (`10/8`, `172.16/12`, `192.168/16`), `0.0.0.0/8`,
`100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `192.0.0.0/24`, `198.18.0.0/15`, `224.0.0.0/4`,
`240.0.0.0/4`, `::/128`, `::1/128`, `fc00::/7`, `fe80::/10`, `ff00::/8`, and IPv4-mapped, NAT64
(`64:ff9b::/96`) and 6to4 (`2002::/16`) addresses embedding one of the IPv4 ranges. The guarded transport uses no HTTP
proxy. An operator MAY exempt prefixes for local development. Provider upstreams are fixed
operator configuration and are not guarded.

### 9.7 Paths

A tail with `.` or `..` segments (literal or percent-encoded) or a backslash is refused: `403` on a
provider route, `404` on a connector route. A tail can therefore never climb out of a connector's
base path.

## 10. Errors and refusals

*Status: stable.*

Every refusal the gateway itself makes is JSON, in a shape both the Anthropic and OpenAI SDKs
surface, with a marker header:

```
HTTP/1.1 403 Forbidden
Content-Type: application/json
X-Jumpdrive-Gateway: refused

{"type":"error","error":{"type":"permission_error","message":"push is not granted to this run"}}
```

| Member | Type | Meaning |
| --- | --- | --- |
| `type` | string | Always `error`. |
| `error.type` | string | The error type (table below). |
| `error.message` | string | Human-readable. Never contains a token, a credential or a request body. Not stable: match on status and `error.type`. |

Example: [`examples/error.json`](examples/error.json).

| Status | `error.type` | Audit `decision` | Cause |
| --- | --- | --- | --- |
| 400 | `invalid_request_error` | `invalid_body` | a provider body the gateway cannot read the way the provider will (section 9.3) |
| 400 | `invalid_request_error` | `too_large` | the request body could not be read |
| 401 | `authentication_error` | `unauthenticated` | no token, two different tokens, or a token that is unknown, expired, superseded, or (JWT) invalid, expired or revoked |
| 402 | `budget_exceeded` | `budget_exceeded` | the budget is spent, or the request's own cap exceeds what is left |
| 403 | `permission_error` | `not_granted` | provider, repository or connector not granted; a connector grant with an unusable `url` |
| 403 | `permission_error` | `endpoint_denied` | provider endpoint not on the allowlist, a websocket upgrade, or a dot-segment tail |
| 403 | `permission_error` | `model_denied` | a model not on the allowlist, or no model named under an allowlist |
| 403 | `permission_error` | `push_denied` | push without `write` |
| 403 | `permission_error` | `egress_denied` | the git or connector upstream resolves to an internal address |
| 404 | `not_found_error` | `unknown_route` | unknown provider, a git request that is not smart HTTP, a connector tail with dot segments |
| 413 | `request_too_large` | `too_large` | body over 32 MiB (provider), 1 GiB (git) or 16 MiB (connector) |
| 415 | `invalid_request_error` | `invalid_body` | a compressed request body on a provider route |
| 429 | `rate_limit_error` | `budget_inflight` | the budget is reserved by requests in flight; `Retry-After: 1` |
| 502 | `upstream_error` | `upstream_error` | the upstream could not be reached or failed mid-request |
| 503 | `unavailable` | `unavailable` | the coordinator, an issuer's JWKS or introspection, or a credential source could not answer |

Answers from an upstream (including its own errors) are passed through unchanged and do not carry
`X-Jumpdrive-Gateway`.

A receiver MUST treat these as refusals:

- **Gateway:** a resolution without a future `expires_at`, with an empty `run_id` or an
  `attempt` below 1, or bound to an attempt below one it has seen; two different presented
  tokens; any JWT failure in section 6, with no fallthrough; any request outside its grant.
- **Coordinator:** a resolve call without the right service secret (`401`); a token for a
  superseded attempt or a stopped run (`409`); an unknown or expired token (`404`/`410`).

## 11. Audit records

*Status: stable.*

The gateway emits **one record per routed request**, forwarded or refused, as one JSON object per
line on standard output. Operational logs go to standard error. Zero-valued optional members are
omitted. Examples: [`examples/audit-record-run.json`](examples/audit-record-run.json),
[`examples/audit-record-jwt.json`](examples/audit-record-jwt.json).

| Member | Type | Always present | Meaning |
| --- | --- | --- | --- |
| `ts` | string, RFC 3339 (UTC) | yes | When the request arrived. |
| `run_id` | string | no | The run, for a resolved run token. |
| `attempt` | integer | no | The attempt, for a resolved run token. |
| `route` | string | yes | `provider`, `git` or `connector`. |
| `destination` | string | no | Provider: its name. Git: `host/owner/repo` (no `.git`). Connector: `connector_id@upstream-host` once the grant is found, else the id. Never a full upstream URL, because connector URLs can embed keys. |
| `method` | string | yes | The HTTP method. |
| `status` | integer | yes | The status sent to the caller. |
| `bytes_in` | integer | yes | Request body bytes read. |
| `bytes_out` | integer | yes | Response body bytes written to the caller. |
| `tokens` | integer | no | What the request was charged against the budget (section 9.4). |
| `tokens_estimated` | boolean | no | `true` when `tokens` is the reservation estimate rather than reported usage. |
| `model` | string | no | The model the request named (the refused one, on `model_denied`). |
| `credential_layer` | string | no | The layer of the credential used (section 4.4). |
| `caller_kind` | string | no | `jwt` for a trusted issuer's token. Absent for run tokens. |
| `issuer` | string | no | The JWT's issuer. On a refused JWT, the only caller member present. |
| `subject` | string | no | The verified `sub`. |
| `client_id` | string | no | The verified `client_id`. |
| `decision` | string | yes | `forwarded`, or the refusal reason (section 10). |
| `duration_ms` | integer | yes | Time from arrival to the end of the response. |

Never recorded: a credential, the caller's token, request or response bodies, prompts.

Records are the gateway's half of a "named destination" egress story: a coordinator may ingest
them as run events. No transport for that is specified yet.

## 12. Security considerations

*Status: stable.*

**The gateway**

- MUST fail closed: no resolved credential, no forward.
- MUST strip every inbound credential header and anything echoing the caller's token (section
  9.2), and MUST NOT forward `X-Forwarded-*` or `Forwarded`.
- MUST keep the two token paths separate (section 3). A trusted issuer's token that fails is never
  retried as a run token, so a forged JWT cannot reach the coordinator, and a run token cannot be
  confused with a principal.
- MUST hold secrets only in memory, never log or audit them, and never quote a resolution body or
  file content in an error.
- MUST guard git and connector dials on the resolved address (section 9.6) and MUST NOT use a
  proxy on that path.
- MUST judge the exact bytes it forwards (section 9.3), so that the model and budget checks cannot
  be bypassed with duplicate keys, case variants, compression or encodings.
- SHOULD be reachable only from the callers it serves (a network policy between sandboxes and the
  gateway).

**The coordinator**

- MUST authenticate the gateway with a secret compared in constant time, and refuse all resolve
  calls when none is configured.
- MUST bind each run token to one attempt and refuse it once the attempt is superseded or
  execution has stopped.
- MUST NOT grant more than the run would have been given directly.
- MUST NOT log the token or the body, and SHOULD send `Cache-Control: no-store`.
- SHOULD rate-limit resolve calls, sized for the gateways' combined cache misses. Callers see a
  `429` from the coordinator as `503`.
- Beware that a `404` from a wrong origin or an unserved version path reads to the gateway as an
  unknown token: a misrouted resolver looks like every caller's token being bad (`401`), not an
  outage (`503`). Serve the versioned path exactly, and treat a gateway whose every caller gets
  `401` as a possible misconfiguration.

**Trusted issuers and operators**

- Use an audience dedicated to the gateway, so a token minted for another service is never
  accepted here.
- Keep access tokens short-lived. JWTs are stateless: without introspection, a revoked session
  stays usable until `exp`.
- Publish new signing keys before using them; the gateway fetches an unknown `kid` at most once
  per 30 s.
- With `require_permissions: false`, a verified principal gets every grant the credential source
  supplies. Use it only for issuers that mint gateway tokens solely for that purpose.
- `gateway:*:write` and `gateway:git:*:write` allow push to every granted repository whose entry
  has `write: true`. Wildcards before `:write` deserve the same review as the repositories they
  cover.
- In a credential-source file, a subject layer's `models` replaces the org's whole. A subject entry
  with `"models": []` lifts the org's allowlist for that subject.
- Credential and config files hold paths to secrets, not secrets. Protect the secret files and the
  gateway's memory; rotating a secret means a restart.

**Callers**

- Send the token only to the gateway, over TLS, in one place per request.
- Expect `401` (re-authenticate or stop), `402` (stop), `429` (retry after `Retry-After`), `503`
  (retry later), and `403` (do not retry: not granted).

## 13. DRAFT: policy by reference

> **Status: DRAFT. Not implemented.** This section proposes how the gateway splits *policy*
> (which grants apply, from which layer) from *secrets* (the credential values). It may change
> without a version bump. Nothing here alters sections 1 to 12.

### 13.1 Direction

Policy comes from the coordinator; secrets come from the edge.

- **Policy, from the coordinator.** For a principal `(issuer, subject)` and optionally a workspace,
  the coordinator answers which grants apply and from which layer (`user`, `workspace`, `org`),
  with the org's locks and the workspace's restrictions already applied. It names each credential
  **by reference**, never by value.
- **Secrets, from the org's own credential source** beside the gateway: a file today, later other
  stores. The gateway resolves each reference locally. A reference with no local secret is
  refused.

A breach of the coordinator then leaks policy, not keys. The coordinator never sees the caller's
access token either: the gateway verifies the token (section 6) and sends only the verified
principal. OAuth refresh moves to the edge with the secrets; the coordinator keeps metadata only
(which credentials exist, their scopes and expiry).

The run-token path (section 4) is unchanged by this draft. Moving runs to the same split is an
open question (section 13.8); the reference format below is designed so a resolution could carry
references in place of values later.

### 13.2 Credential reference

A **credential reference** names one secret without carrying it.

```json
{ "kind": "provider_key", "binding": "anthropic", "layer": "user", "owner": "<subject>" }
```

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `kind` | string | yes | `provider_key` (a model provider key), `oauth` (an OAuth access token), `api_key` (a service API key) or `git` (a git HTTP password or token). |
| `binding` | string | yes | What the credential is for: a provider name for `provider_key` (`anthropic`, `openai`, `openrouter`), otherwise a provider or host (`git.example.com`). Matches `^[a-z0-9][a-z0-9_.:-]{0,127}$`. |
| `layer` | string | yes | `user`, `workspace` or `org`. `platform` is not valid in a reference. |
| `owner` | string | for `user` and `workspace` | `user`: the principal's `sub`. `workspace`: the workspace id. Absent for `org`: the org is the gateway deployment's own. |

- `kind:binding` is the same pair, in the same syntax, that a coordinator's environment
  definitions already use to name credentials (`provider_key:anthropic`, `git:git.example.com`).
  The string form `"<kind>:<binding>"` is the lookup key in an edge store (section 13.5).
- The edge store is keyed by `(issuer, layer, owner, kind, binding)`.
- A `user` reference whose `owner` is not the verified `sub` of the request MUST be treated as a
  malformed answer (section 13.6). A coordinator can therefore never make one person's request
  spend another person's credential.

### 13.3 Policy request

Proposed endpoint, authenticated like section 4.1 with the gateway's service secret:

```
POST {coordinator_origin}/internal/gateway/v1/policy
Authorization: Bearer <gateway service secret>
Content-Type: application/json
```

Example: [`examples/draft-policy-request.json`](examples/draft-policy-request.json).

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `version` | integer | yes | `1`. |
| `principal.issuer` | string | yes | The verified `iss`. |
| `principal.subject` | string | yes | The verified `sub`. |
| `principal.client_id` | string | no | The verified `client_id`. |
| `principal.token_id` | string | no | The token's `jti` or digest (section 6.2). For the coordinator's audit; it MUST NOT be used as a credential. |
| `workspace` | string | no | The workspace the caller acts in. Where it comes from is open (section 13.8). |

The access token itself is never sent.

### 13.4 Policy response

`200` with one JSON object. It has the shape of a resolution's `grants` and `budget` (section
4.3), except that every credential **value** member (`key`, `password`, `token`) is replaced by
one `credential_ref`. Example with every member present:
[`examples/draft-policy-response.json`](examples/draft-policy-response.json).

| Member | Type | Required | Meaning |
| --- | --- | --- | --- |
| `version` | integer | yes | `1`. |
| `principal` | object | yes | `issuer` and `subject`, echoed. MUST equal the request's. |
| `workspace` | string | no | Echoed when the request named one. |
| `expires_at` | string, RFC 3339 | no | How long this policy may be reused. The gateway never reuses it past the token's `exp`. |
| `grants.providers.<name>` | `{ credential_ref }` | no | A provider grant. |
| `grants.models` | array of strings | no | As in section 4.3. |
| `grants.git[]` | `{ host, owner, repo, write, username, credential_ref }` | no | As in section 4.3, with `credential_ref` for `password`. A public repository omits `credential_ref`. |
| `grants.connectors[]` | `{ id, url, header, scheme, credential_ref }` | no | As in section 4.3, with `credential_ref` for `token`. Policy carries the `url`; the egress guard still applies. |
| `budget` | `{ max_tokens }` | no | As in section 6.5. |

A grant that carries a credential value instead of, or as well as, a `credential_ref` is a
malformed answer. A coordinator speaking this contract never sends secrets.

| Status | Meaning | The gateway answers the caller |
| --- | --- | --- |
| `200` | the policy above | proceeds |
| `404` | the coordinator does not know this principal (or workspace) | `403 not_granted` on every route |
| `401` / `403` | the gateway's service secret is wrong | `503` |
| anything else, a timeout (5 s) | unavailable | `503` |

The gateway then applies `require_permissions` narrowing (section 7) as today: policy from the
coordinator and permissions in the token both have to allow a grant.

### 13.5 Resolving references at the edge

For each grant used by a request, the gateway looks up the grant's reference in the org's
credential source and injects the value as in section 9.2.

- **No fallback across layers.** If the referenced layer holds no secret, the gateway MUST NOT try
  another layer. The coordinator chose the layer, and the layer decides who pays.
- **Missing secret.** The request is refused:

  ```
  HTTP/1.1 403 Forbidden
  X-Jumpdrive-Gateway: refused

  {"type":"error","error":{"type":"permission_error","message":"the credential this grant names is not held by this gateway"}}
  ```

  with audit `decision: "credential_missing"` (a new value) and `credential_layer` from the
  reference. The gateway logs a warning naming the reference's `kind`, `binding`, `layer` and
  `owner`, never a value. Other grants in the same policy are unaffected. A missing secret is not
  retried by the caller: an operator has to add it.
- **Present but not usable now** (an OAuth token the edge cannot currently refresh, a store that
  does not answer): `503 unavailable`, decision `unavailable`.
- **Edge store file.** One possible shape, extending section 8 with a `version` member, so a
  gateway that does not know it refuses to start
  ([`examples/draft-edge-store.json`](examples/draft-edge-store.json)):

  ```
  { "version": 1, "issuers": { "<iss>": {
      "org":        { "<kind>:<binding>": { "secret_file": path } },
      "workspaces": { "<workspace id>": { "<kind>:<binding>": { "secret_file": path } } },
      "subjects":   { "<sub>": { "<kind>:<binding>": { "secret_file": path } } } } } }
  ```

### 13.6 Refusals specific to this draft

The gateway MUST treat the whole policy answer as malformed (`503`, logged as an error, not
cached) when:

- `version` is missing or unknown;
- `principal` differs from the request's;
- a grant carries a credential value, or more than one credential;
- a reference has an unknown `kind` or `layer`, a `platform` layer, a `binding` outside the
  syntax, a missing `owner` on `user` or `workspace`, or a `user` `owner` that is not the verified
  subject.

### 13.7 Caching

As section 4.5: positive answers only, keyed by `(issuer, subject, workspace)`, reused for at most
the configured TTL, the answer's `expires_at` and the token's `exp`. An upstream `401` drops the
cached policy, so a refreshed or rotated secret is picked up at once.

### 13.8 Open questions

1. Where the workspace comes from: a claim the issuer adds to the access token, or a request
   header the gateway trusts only alongside a matching permission.
2. Whether runs move to the same split, with `credential_ref` replacing values in a resolution,
   and what that means for a runner's provider keys.
3. Which edge stores come first besides the file, and reloading them without a restart.
4. Whether front doors acting for a person need token exchange (an RFC 8693 `act` claim), or
   whether `client_id` is enough.

## 14. Notes on the implementation

*Informative.*

**Run tokens in the reference coordinator.** The Jumpdrive control plane mints each run token as
a signed, purpose-scoped global id for the run (purpose `run_gateway`), carrying the attempt and
its expiry inside the signed part. A token minted for another purpose, such as posting a run's
result, never resolves. Its lifetime equals the attempt's callback-token lifetime. It answers
`404` for expired tokens (it cannot tell them from forged ones) and never sends `410`.

**What the reference coordinator sends.** `budget` is `{}` (uncapped); `models` holds the run's
resolved model, or is empty when none is pinned; connector grants omit `header` and `scheme`; git
grants always send `username: "x-access-token"` and an empty `password` for a public repository;
the `platform` layer is not yet granted through the gateway. stdio connectors are never granted:
they run in-process, so the gateway has no route for them.

**Where documentation and code differed** (this spec follows the code):

- The gateway README lists `410` for an expired token. The gateway handles it; the reference
  coordinator never sends it (above).
- The gateway README says every request is audited. Paths that match no route (section 2.1) are
  answered by the HTTP server directly, with no envelope and no audit record. `/healthz` is not
  audited.
- The gateway README says git gets a `WWW-Authenticate` challenge when no token is sent. The code
  sends it on every `401` on the git route.
- The gateway README gives `typ` as `JWT` or `at+jwt`. The code also accepts `application/at+jwt`,
  case-insensitively.
- A request body that cannot be read is answered `400` but audited as `too_large`.

## Source

Read for this spec:

- `rarebit-one/jumpdrive-gateway` at `3cd6a19`: README and the packages for the proxy, resolver,
  JWT verification, principals, policy, credential source, budget, audit and configuration.
- `rarebit-one/jumpdrive-web` at `16fb786`: the control plane's internal gateway-resolve
  controller and its run-gateway services (token, resolution).
- Section 13 is drawn from the agent access ADR (`rarebit-one/jumpdrive-web` pull request #1305,
  at `2a3c196`), Decision 3 and owner decision 10.
