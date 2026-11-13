# Voidbind (Void-Which-Binds)

Void-Which-Binds ("Voidbind" for short) is a self-sovereign identity and key protocol. A person is
an Ed25519 **genesis key** derived from a written recovery secret, plus a set of **device keys**
that any current device can extend or shrink. An organisation is a genesis key with a **roster**
of persons and roles. A relying party trusts a person or an organisation by **pinning** its
genesis key and checking everything else offline against that pin. There is no central
authority and no shared secret.

This spec covers what crosses the wire between:

- **devices** (a phone authenticator, a desktop CLI, a browser holding a passkey) that hold
  member keys;
- **relying parties (RPs)**, which pin persons or organisations and verify devices;
- an organisation's **broker**, which is an RP for its own roster, holds approval and
  delegation state, and acts as an OpenID Provider for the organisation's other apps;
- the **pairing relay**, an untrusted store-and-forward box used while enrolling a device.

Recovery from the written secret already has its own public spec:
[rarebit-one/void-which-binds-recovery-spec](https://github.com/rarebit-one/void-which-binds-recovery-spec).
This spec links to it and does not restate it.

## Documents

| Document | Covers | Status |
| --- | --- | --- |
| [identity.md](identity.md) | key strings and person ids, the enrolment cert, membership ops and their evaluation, the possession proof, the `Device` credential and its headers | stable |
| [grants.md](grants.md) | the capability grant, the delegation grant and its proof of possession, the broker nonce, scopes, the `webauthn:` passkey signature | stable (broker nonce route: stable in the reference broker) |
| [pairing.md](pairing.md) | the pairing relay, the QR invite, commit, reveal and SAS, the sealed admission, pairing refusal | stable |
| [weblogin.md](weblogin.md) | QR web login (v1) and number matching (v2) | stable |
| [roster.md](roster.md) | the org roster op, its evaluation, re-roots, how an RP trusts persons through a roster | stable (roster push: draft) |
| [approval.md](approval.md) | the action-approval challenge, the opaque wake, the authenticated fetch, the broker's approve routes | stable byte layer and fetch; draft broker routes |
| [oidc.md](oidc.md) | the broker as an OpenID Provider: the EdDSA ID token, key pinning, SET deprovisioning, back-channel approval (CIBA) | stable token formats and RP checks; draft issuer endpoints |

## Overview

### Parties and transport

Every exchange in this spec is HTTP. Production deployments MUST use HTTPS; plain HTTP appears
only in local development. Request and response bodies are JSON (`application/json`) unless a
section says otherwise. Signed statements are carried as **compact tokens** inside headers or
JSON fields (below), so they keep their exact bytes end to end.

Nothing in this protocol depends on transport security for *integrity*: every statement that
grants anything is signed and checked against a pinned key. TLS is still required, for
confidentiality and so that a passive observer cannot correlate wakes, logins and approvals.

### Authentication, in one paragraph

An RP pins a person's genesis key (`ed25519:<hex>`) or an organisation's id plus its founding
roster op. A device authenticates by presenting the membership op that admitted it, the other
ops the RP may lack, and a short-lived **possession proof** signed by the device key
(`Authorization: Device <op>~<proof>`). The RP evaluates the ops against the pin, checks the
proof, and only then records the new ops. The other flows (web login, approvals, delegations,
pairing refusals) are the same idea with a different signed preimage.

### Encodings shared by every section

| Thing | Encoding |
| --- | --- |
| base64url | RFC 4648 §5, **unpadded** (`=` never appears). Every binary field on this wire uses it unless stated |
| Ed25519 public key | `ed25519:` followed by 64 **lowercase** hex characters. This is the only accepted spelling. A verifier MUST refuse upper case, surrounding whitespace, or any other prefix rather than normalise it |
| X25519 public key | `x25519:` followed by 64 lowercase hex characters |
| WebAuthn ES256 passkey | `webauthn:es256:` followed by 130 lowercase hex characters: the uncompressed SEC1 P-256 point (`04‖X‖Y`) of a valid point ([grants.md](grants.md#the-webauthn-member-key)) |
| org-managed person id | `mp:` followed by 32 lowercase hex characters (16 random bytes) |
| op hash | `sha256:` followed by the lowercase hex SHA-256 of the **token string's bytes** |
| compact token | `base64url(body) "." base64url(signature)`. `body` is a JSON object; the signature is Ed25519 over the body bytes (or, for a `webauthn:` signer, a WebAuthn envelope, see [grants.md](grants.md#the-webauthn-member-key)) |
| framed preimage | `frame(p) = uint64_be(len(p)) ‖ p`. A framed preimage is the concatenation of framed fields, the first being a domain label |
| times | integer Unix seconds |

### Signed tokens and the `typ` claim

Every compact token body names its kind in a `typ` member, which is always the **second** member,
immediately after `v`. A verifier knows which `typ` it accepts and MUST refuse a body whose `typ`
is absent, not a JSON string, a different value, or spelt with a case-variant key (`Typ`,
`TYP`), before it trusts any other field. The values are compared byte for byte.

| Kind | `typ` | `v` | Signed by | Defined in |
| --- | --- | --- | --- | --- |
| enrolment cert | `void-which-binds.cert` | 1 or 2 (mint 2) | the person's genesis key | [identity.md](identity.md#the-enrolment-cert) |
| membership op | `void-which-binds.op` | 3 | genesis or a member device | [identity.md](identity.md#membership-ops) |
| possession proof | `void-which-binds.possession` | 2 | a device key | [identity.md](identity.md#the-possession-proof) |
| capability grant | `void-which-binds.grant` | 1 | a pinned issuer key | [grants.md](grants.md#capability-grant) |
| delegation grant | `void-which-binds.delegation` | 1 | a member key of a person | [grants.md](grants.md#delegation-grant) |
| delegation proof | `void-which-binds.delegation-pop` | 1 | the agent key | [grants.md](grants.md#agent-proof-of-possession) |
| pairing refusal | `void-which-binds.pair-refusal` | 1 | the pairing initiator | [pairing.md](pairing.md#refusal) |
| roster op | `void-which-binds.roster` | 1 | the org authority key or an admin person | [roster.md](roster.md#the-roster-op) |

Because ops are identified by the hash of their token, **minting is deterministic**: a minter
MUST emit members in the order each section lists, as compact JSON with no insignificant
whitespace, using the escaping of Go's `encoding/json` (which escapes `<`, `>` and `&` as
`<`, `>`, `&`). A verifier never re-serialises: it checks the signature over the
received body bytes and only then parses them. Where a section says the body "must be the
canonical encoding of its claims", the verifier additionally re-encodes and compares.

The JOSE tokens of [oidc.md](oidc.md) are ordinary compact JWS and use the JOSE `typ` header
instead (`JWT`, `secevent+jwt`, `vwb-approval+jwt`).

Signatures that are not tokens (web-login and approval assertions, cosignatures, pairing
commitments) sign a **domain-separated** preimage, so no signature made for one purpose can be
replayed as another. The labels in use:

| Label | Used for |
| --- | --- |
| `void-which-binds-cosig-v1\x00` (prefix) | a cosignature on a membership op |
| `void-which-binds-roster-cosig-v1\x00` (prefix) | a cosignature on a roster op |
| `void-which-binds-roster-reroot-v1\x00` (prefix) | a re-root successor's signature |
| `void-which-binds/pairing/commit/v2` | the pairing key commitment |
| `void-which-binds/pairing/sas/v2` | the pairing short authentication string |
| `void-which-binds/pairflow/refusal/session/v1` | binding a refusal to one pairing |
| `void-which-binds/space-key-wrap/v1` | the X25519 seal (HKDF info) |
| `void-which-binds/weblogin/challenge/v1`, `…/v2` | web-login assertions |
| `void-which-binds/approval/action/v1` | the action digest |
| `void-which-binds/approval/challenge/v1` | an approval assertion |
| `void-which-binds/approval/fetch/v1` | an approval fetch proof |
| `void-which-binds/webauthn/challenge/v1` | deriving a WebAuthn challenge from a body |
| `void-which-binds/roster/enrol-proof/v1` | a managed person's key-enrolment proof |

### Versioning

There is no negotiation. Each artefact carries its own version and a receiver MUST refuse a
version it does not implement; it never guesses.

- **Tokens**: `typ` names the kind, `v` the version *within* that kind. An unknown `typ` is
  `wrong_type`; a known `typ` with an unknown `v` is `malformed`.
- **Preimages and key derivations**: the version is part of the domain label. A new format is a
  new label, never a reinterpretation of an old one.
- **URIs**: the pairing invite carries `v=4`; any other value is refused.
- **Generations.** This spec describes **generation 2** (gen2) only: every string above is the
  `void-which-binds` spelling. The retired generation-1 strings (`voidbind.*` token types,
  `voidbind/…` labels, the `voidbind:` URI scheme with invite `v=3`, `Voidbind-*` headers, and
  `heyarr1…` recovery secrets) MUST be refused, never dual-parsed. A gen2 identity is a new
  identity; there is no migration on the wire.

### Status

Each section of each document is marked **stable** (implemented in the Go core library, relied
on by released implementations, and pinned by golden vectors) or **draft** (accepted design that
no released component implements yet; it may change without a version bump). A stable section
that the reference broker implements only as a pilot is marked as such.

### Golden vectors

The Go core generates cross-implementation vectors (test-only seeds, never real keys) for the
membership op set, the `Device` scheme, roster ops, delegations, approvals, WebAuthn
assertions, the OIDC tokens and SETs. The public Kotlin port carries copies under
`src/jvmTest/resources/vectors/` in
[rarebit-one/void-which-binds-kmp](https://github.com/rarebit-one/void-which-binds-kmp), and an
implementation of this spec SHOULD replay them byte for byte. A vector that passes in one
implementation and fails in another is a divergence in the port.

### Examples

[`examples/`](examples/) holds one JSON file per message or token body, with every optional
field present. Keys, hashes and base64url values have the right length and alphabet but are
built from repeated bytes: they are placeholders, not valid keys, and no signature in them
verifies. A compact token in an example is a real-shaped token over the example body with a
zero signature.

### Out of scope

- **Recovery**: see the recovery spec linked above. It defines the `void-which-binds1…` secret,
  the HKDF derivation of the genesis key, the fingerprint, SLIP-39 shares and space-key
  wrapping.
- **The wake (notify) plane.** A broker or RP may wake a person's devices through a push
  channel. The wake carries only a public tuple: `void-which-binds:login?rp=<origin>&id=<id>`
  (the same string a login QR encodes) or `void-which-binds:approve?h=<handle>`
  ([approval.md](approval.md#the-approve-tuple)). It never carries key material, a challenge
  or a match number; a woken device always fetches the real challenge over TLS. The
  subscription and delivery API is not specified here.
- **Device key storage.** How a device keeps its key non-extractable (Secure Enclave, StrongBox,
  TPM, a passphrase-sealed file) is the device's business. The wire is the same.
- **Encrypted spaces.** The X25519 seal is described only as far as pairing uses it.

## Source

Read at these commits:

| Repo | Commit | Role |
| --- | --- | --- |
| rarebit-one/void-which-binds-go | `e2cf9ba` (after release v0.28.1) | the Go core: wire contract, verifiers, ADRs 0001–0025, golden vectors |
| rarebit-one/void-which-binds-kmp | `d1fbab1` | the Kotlin Multiplatform device library (public) |
| rarebit-one/void-which-binds-web | `e258cc8` | the browser web-login client (public) |
| rarebit-one/moneta | `4f62850` | the reference broker (one process per organisation) |
| rarebit-one/standard_id-void_which_binds | `472f79d` | the Rails RP plugin: OIDC login and SET deprovisioning (public) |
| rarebit-one/void-which-binds-recovery-spec | `bf77334` | recovery (public), linked, not restated |

Where an ADR and the code disagree, this spec follows the code. The disagreements found are
noted in the section they affect.
