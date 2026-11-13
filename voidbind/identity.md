# Identity, membership and the `Device` credential

**Status: stable.** Implemented in the Go core (`identity`, `enrolment`, `rp`, `deviceclient`)
and the Kotlin device library; pinned by the `membership`, `op-log-cap` and
`device-scheme-vector` golden vectors. Encodings and the `typ` rule are in the
[README](README.md#encodings-shared-by-every-section).

## The identity model

### Person (sovereign identity)

- A person **is** an Ed25519 key pair, the **genesis key**. Its public half, rendered
  `ed25519:<64 lowercase hex>`, is the person's id everywhere: in `usr` claims, in an RP's pins,
  as an OIDC `sub` ([oidc.md](oidc.md#the-id-token)), as a roster `mem`
  ([roster.md](roster.md)).
- The genesis key is derived deterministically from a 32-byte **recovery secret** written down
  as a `void-which-binds1…` bech32m string. The derivation, the user fingerprint and SLIP-39
  shares are in the
  [recovery spec](https://github.com/rarebit-one/void-which-binds-recovery-spec). No device
  stores the secret or the genesis private key.
- Genesis is a **dormant, permanent member** of its own identity. It signs the first device add
  and recovery re-adds, and nothing else in normal use. It can never be added, removed or used as
  a device.

### Devices

- Each device holds its own **signing key** (Ed25519, `ed25519:…`) and, normally, an
  **encryption key** (X25519, `x25519:…`) that others seal secrets to. A device never shares
  them; a new device gets new keys and is admitted by pairing ([pairing.md](pairing.md)).
- The person's **membership** is the set of devices currently admitted, defined by a log of
  signed **membership ops** (below). Any current member device can add or remove another.
- A **passkey** may also be a member key, rendered `webauthn:es256:<130 hex>` (the uncompressed
  P-256 point). It can sign approvals, approval fetches and delegations through a WebAuthn
  assertion ([grants.md](grants.md#the-webauthn-member-key)), but it cannot sign membership
  ops, cosignatures or possession proofs, and does not count toward the cosignature threshold.

### Person identifier formats

| Form | Meaning | Where it appears |
| --- | --- | --- |
| `ed25519:<64 hex>` | a sovereign person (their genesis key), a device key, an org id, an agent key | everywhere a key is named |
| `mp:<32 hex>` | an **org-managed person**: an org-scoped id, 16 random bytes chosen by the enrolling admin, whose keys the org's admins enrol in the roster. It outlives every key | roster `mem`/`usr`, delegation `usr`, OIDC `sub` ([roster.md](roster.md#members-are-persons)) |
| `webauthn:es256:<130 hex>` | a passkey member key | membership `dev`, roster `key`, delegation `iss` |
| `x25519:<64 hex>` | an encryption key | membership `denc`, pairing reveal `enc` |

A person id is never a device key and a device key is never a person id: verifiers MUST keep
them apart (for example, an op whose `dev` equals its `usr` is malformed).

## The enrolment cert

The original, single-signer admission: the genesis key vouches for one device. A cert **is** a
membership op (an `add` by genesis citing nothing) and is read as one.

Body (`examples/cert-body.json`), members in this order:

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `v` | int | yes | 2 (a verifier also accepts 1) |
| `typ` | string | yes | `void-which-binds.cert` |
| `usr` | key | yes | the person's genesis key; also the signing key |
| `dev` | key | yes | the device's signing key |
| `denc` | key | no | the device's X25519 key; treated as opaque by evaluation |
| `iat` | int | yes | issued at |
| `exp` | int | yes | expiry. The default life is 90 days |

Signed by `usr`. Minters SHOULD now mint ops instead; certs remain valid input.

## Membership ops

An op says "member `by` adds (or removes) device `dev` to (from) identity `usr`", and carries the
causal evidence that `by` was a member when it said so: `prev`, the hashes of the ops `by` had
seen (its **heads**). Ops form a hash DAG.

Body (`examples/op-add-body.json`, `examples/op-remove-body.json`), members in this order:

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `v` | int | yes | 3 |
| `typ` | string | yes | `void-which-binds.op` |
| `usr` | key | yes | the identity (genesis key) |
| `op` | string | yes | `add` or `remove` |
| `dev` | key | yes | the device added or removed: `ed25519:` or `webauthn:es256:`. Never `usr` |
| `denc` | key | no | `add` only: the device's encryption key. A later add may rotate it; the most recent effective add wins |
| `by` | key | yes | the signer, `ed25519:` only. Equal to `usr` for a genesis-signed op |
| `prev` | array of op hash | yes | the signer's heads, **sorted and de-duplicated**, at most 64. MAY be empty only when `by == usr` |
| `cosig` | array | no | cosignatures, see below. Omitted when empty |
| `iat` | int | yes | issued at |
| `exp` | int | `add`: yes; `remove`: MUST be absent | the add's expiry. Removes never expire |

The op's id is `sha256:` + hex(SHA-256(token string)). Every key member MUST be the canonical
rendering, byte for byte; anything else makes the op `malformed`.

**Cosignatures.** A `cosig` entry is `{"by": <ed25519 key>, "sig": <base64url>}`, where `sig` is
Ed25519 over `"void-which-binds-cosig-v1\x00" ‖ core`. `core` is the op's body re-encoded with
`cosig` omitted and `typ` kept: because `cosig` is omitted when empty, the core is exactly the
body the op would have with no cosignatures. The primary signature covers the whole body,
cosignatures included.

### Evaluation

`Evaluate(usr, ops, now)` is a pure function of the **set** of ops and the clock: replicas that
hold the same ops reach the same view whatever order they learned them in. An implementation
MUST give the same verdicts as the golden vectors; the rules are:

1. **Structure.** The token parses, `typ` and `v` are right, keys are canonical, the signature
   verifies under `by`, `usr` matches, and every `prev` names a structurally valid op in the set
   with `iat ≤` this op's. A failure is **rejected** (`malformed`, `bad_signature`,
   `foreign_usr`, `bad_prev`) and the op is uncitable; anything citing it is `bad_prev` too.
   A missing `prev` is a rejection: authority cannot be judged against a past the evaluator has
   not seen.
2. **Authority.** A genesis-signed op is authorised. Any other op is authorised iff `by` is a
   member in the op's own `prev` closure at the op's `iat`. Otherwise it is **ineffective**
   (`unauthorised`): it stays in the DAG and may be cited, but changes nothing.
3. **Remove wins, causally.** A device is a member iff it has an authorised add, inside its
   window, that causally follows every effective remove of it, and, if there is such a remove,
   that add is genesis-signed. So a remove concurrent with an add wins, a member can never
   re-add a removed device, and only a genesis re-add that cites the remove restores it.
   A device may remove itself.
4. **Seniority resolves concurrency.** When a remove and an op by the removed device are
   concurrent (neither in the other's closure), the device admitted earlier wins: authorised
   ops are replayed in seniority order of their signer (genesis first, then by each device's
   earliest authorised add: causal depth, then `iat`, then hash), and a junior's concurrent op
   is `outranked`. Nothing in a remove's own closure is undone.
5. **Threshold.** Let N be the number of distinct non-genesis Ed25519 devices that have **ever**
   held an authorised add in the set. When N ≥ 3, a member-signed remove takes effect only with
   **two** distinct member signatures (the primary plus a valid cosignature from a member of the
   op's closure); otherwise it is `under_threshold`. Genesis removes bypass the threshold. The
   threshold is checked before seniority.
6. **History cap.** At most 10,000 well-formed ops are evaluated. Over that, only the anchored
   history (ops by genesis, by devices transitively added by anchored keys, and what they cite)
   is kept and the rest are rejected `unanchored`; if the anchored history alone exceeds 10,000
   the whole set is refused.

The window of an add is judged with a **5-minute skew margin** that only ever shortens it:
an add is not yet valid while `now + 5 min < iat`, and expired once `now ≥ exp − 5 min`.
A device renews itself by signing a fresh add of its own key while its current add is valid.

The view returns the members (each with its admitting op hash, admitted-at, latest expiry and
current `denc`), the removed devices, the heads (sorted), and the rejected and ineffective op
hashes with their reasons (`unauthorised`, `outranked`, `removed`, `superseded`, `expired`,
`not_yet_valid`, `under_threshold`).

## The possession proof

A membership op is public: anyone who has seen one can present it. The holder of the device key
proves possession by signing a short-lived token bound to the op it presents.

Body (`examples/possession-body.json`):

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `v` | int | yes | 2 |
| `typ` | string | yes | `void-which-binds.possession` |
| `crt` | base64url | yes | SHA-256 of the presented op (or cert) **token string**. Note: base64url of the raw digest, not the `sha256:<hex>` op-hash form |
| `iat` | int | yes | issued at |
| `exp` | int | yes | at most 2 minutes after `iat` |

Signed by the device key named in the op's `dev` (Ed25519 only; a passkey cannot make one).
A verifier refuses a proof whose `iat` is more than **30 seconds** in its future, and refuses it
strictly at `exp` (no grace on that side). A fresh proof SHOULD be minted per request.

## The `Device` credential

A device authenticates an HTTP request to an RP with:

```
Authorization: Device <op>~<possession>
Void-Which-Binds-Membership: <op>,<op>,…      (optional)
Void-Which-Binds-Grant: <grant>               (optional)
```

- `<op>` is the device's **admitting op**: the effective add that admitted it (a v3 add or a
  cert). `~` separates it from the possession proof over that op.
- `Void-Which-Binds-Membership` carries the membership ops the device knows, comma-separated, at
  most **64** tokens (each budgeted at 1 KiB). Ops are self-authenticating, so the header needs
  no integrity of its own. It lets an RP that has never met the device's admitter evaluate the
  admission on first contact. Ops of several `usr` values may share the header; the RP routes
  them by `usr`.
- `Void-Which-Binds-Grant` carries an optional capability grant ([grants.md](grants.md)).
- An organisation request adds `Void-Which-Binds-Org` and `Void-Which-Binds-Roster`
  ([roster.md](roster.md#how-a-relying-party-trusts-persons-through-a-roster)).

`examples/device-request-headers.json` shows every header.

Routes that carry ops in a JSON body instead (web-login approve, approval fetch) admit the same
64 ops and cap the body at 96 KiB (64 × 1 KiB plus 32 KiB of envelope).

### What the RP checks, in order

The RP MUST NOT record anything until step 6.

1. Read `usr` from the op body **as a hint only**, and look up the pinned genesis key for it. If
   it is not pinned, refuse `unknown_user` (enrol before trust).
2. Verify the op: it parses, is correctly typed, its signature verifies under its `by`, it names
   that `usr`, and it is an `add` (`malformed`, `bad_signature`).
3. Evaluate the identity over the RP's recorded ops ∪ the presented ops ∪ the credential op, in
   memory.
4. Require the op's device to be a current member admitted by an effective add: `expired` or
   `not_yet_valid` for a lapsed window, `removed` for a removed device, `not_member` for an
   admission nobody authorised (or one citing ops the RP has not seen; the device should present
   them).
5. Verify the possession proof under the device key, bound to the credential op
   (`possession_invalid`, or the finer `malformed`/signature/expired/not-yet/cert-mismatch).
6. **Only now** record the newly seen ops (a union by hash). A refused request writes nothing.

Refusal words are the RP's to map to HTTP; the reference broker answers `401` for
authentication failures and `403` for "authenticated but not allowed". A request whose
`Authorization` header is empty or unreadable is `malformed` without further evaluation, and
more than 64 presented ops is refused before evaluation.

## Security considerations

- **Pin, then evaluate.** A device's own claims select which pin to check, never what to trust.
- **Possession before record.** Without step ordering above, a replayed public op could write
  attacker-chosen (but validly signed) ops into an RP's log.
- **Canonical keys.** A verifier that trims or case-folds keys can be made to count one key as
  two signers, or one person as two.
- **Clock skew** only ever shortens a window, so a skewed clock refuses a valid statement rather
  than honouring an expired one.
- **Removal propagates by presentation.** An RP learns a remove when any member presents it (or
  the RP is told by a broker). Until then it honours the removed device; deployments SHOULD have
  each device present its full known op set.

## Code and documentation notes

- ADR-0007 names the membership header `Voidbind-Membership`; that is the retired gen1 spelling.
  The code and this spec use `Void-Which-Binds-Membership`.
- The web-login approve body calls the admitting op `cert` for historical reasons; it accepts a
  v3 add as well ([weblogin.md](weblogin.md)).
