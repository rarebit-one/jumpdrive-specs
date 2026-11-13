# Organisations: the roster and roster trust

**Status: stable**, except where marked. Go core `roster` (op format, `Evaluate`, re-roots,
the enrolment proof) and `rp` (`Roster`, `CheckOrg`); pinned by the `roster`, `rp-roster` and
`enrol-proof` golden vectors. The reference broker builds its roster checks on these.

## The organisation

An **organisation** is an identity like a person's: a recovery secret derives an Ed25519 genesis
key, and the **org id** is that founding key, rendered `ed25519:<hex>`. The org id never changes.
The key that *signs* for the org (the **authority key**) starts as the founding key and can move
to a successor by a **re-root** (below).

An org has **no device membership log**. An RP MUST NOT pin an org id as a person or evaluate a
membership log for it. The org's only log is its **roster**: an op log of type
`void-which-binds.roster` that reuses the compact token, the `prev` hash DAG and the cosignature
idea of [identity.md](identity.md#membership-ops), with its own evaluator.

### Members are persons

| Kind | `mem` | The person's keys | Who changes them |
| --- | --- | --- | --- |
| sovereign | the person's genesis key, `ed25519:<hex>` | the devices in the person's own membership log | only the person |
| org-managed | `mp:<32 lowercase hex>` (16 random bytes chosen by the enrolling admin) | keys the org's admins enrol in the roster (`ed25519:` or `webauthn:es256:`) | only the org's admins, by quorum |

A managed person is for someone who will not hold their own recovery secret. Only `ed25519:`
keys can sign roster ops; an enrolled `webauthn:` key can approve, fetch and delegate but never
sign a roster op, a cosignature or a possession proof.

### Roles

```
⊥ (not on the roster)  <  viewer  <  member  <  admin  <  owner
```

`viewer` and `member` mean nothing to the evaluator; RPs and the broker map roles to scopes.
`admin` and `owner` are the **admin persons**: they sign roster ops and count toward the quorum.
Changing an owner (adding, removing, demoting one, or changing a managed owner's keys) also needs
a counted signature from a current owner (`owner_required`). A role MAY carry an expiry.

## The roster op

Body (`examples/roster-op-*-body.json`), members in exactly this order:

| Member | Type | When | Meaning |
| --- | --- | --- | --- |
| `v` | int | always | 1 |
| `typ` | string | always | `void-which-binds.roster` |
| `org` | key | always | the org id |
| `op` | string | always | `set`, `remove`, `enrol`, `unenrol`, `reset`, `reroot`, `resolve` |
| `mem` | person id | `set`, `remove`, `enrol`, `unenrol` | the person acted on (`enrol`/`unenrol`: a managed `mp:` id). Never the org id or an authority key |
| `role` | string | `set` | `viewer`, `member`, `admin` or `owner` |
| `key` | member key | `enrol`, `unenrol` | the key enrolled or unenrolled |
| `exp` | int | optional on `set` and `enrol` | the grant's expiry, strictly after `iat` |
| `succ` | key | `reroot` | the successor authority key |
| `pick` | op hash | `resolve` | the conflicting re-root chosen |
| `by` | key | always | the primary signer, `ed25519:` |
| `usr` | person id | absent for the authority key; else required | the person `by` signs for |
| `bprev` | array of op hash | sovereign `usr` signed by a device only | that person's membership heads as the signing device knows them, sorted, at most 64 |
| `prev` | array of op hash | always | the signer's roster heads, sorted, at most 64. MAY be empty only for an authority-key op |
| `cosig` | array of entry | optional | at most 8 cosignatures |
| `succsig` | base64url | `reroot` | the successor's signature |
| `iat` | int | always | issued at, positive |

Any member an op does not take MUST be absent, and the body MUST be exactly the canonical
encoding of its claims; anything else is `malformed`. A field the op needs that is missing is
`malformed`.

**Signer shapes.** The primary signer and each cosignature entry are one of:

| Signer | `by` | `usr` | `bprev` |
| --- | --- | --- | --- |
| the org authority key (primary only) | the authority key | absent | absent |
| a sovereign person's device | the device key | the person's genesis key | the person's heads |
| a sovereign person's genesis | `== usr` | the genesis key | absent |
| a managed person's enrolled key | the `ed25519:` key | the `mp:` id | absent |

A cosignature entry is `{"by", "usr", "bprev"?, "sig"}` (a cosignature always names `usr`), and
`sig` is Ed25519 over:

```
"void-which-binds-roster-cosig-v1\x00" ‖ core ‖ 0x00 ‖ usr ‖ 0x00 ‖ join(bprev, ",")
```

where `core` is the body re-encoded with `cosig` and `succsig` omitted. The domain differs from a
membership cosignature's, so neither can count as the other.

The **founding op** is an authority-key `set` of the first `owner`, with `prev = []`
(`examples/roster-op-founding-body.json`). An RP pins it beside the org id.

## Evaluation

`Evaluate(org, rosterOps, personOps, now)` is a pure function of the two op sets and the clock.
Implementations MUST match the golden vectors. In outline:

1. **Structure.** Parses, `typ` exact (`wrong_type`), `v` 1, `org` matches, primary signature
   verifies, every `prev` is a structurally valid roster op with `iat ≤` this op's, every
   `bprev` resolves to person ops the evaluator holds with `iat ≤` this op's
   (`missing_person_context` otherwise), fields match the `op`. A failure is **rejected** and
   uncitable (`malformed`, `bad_signature`, `foreign_usr`, `bad_prev`, `unanchored`).
2. **Whose signature counts.** For each signature: it verifies; for a sovereign `usr`, `by` is
   `usr` itself or a member of `usr`'s membership **as of `bprev` at the op's `iat`**; for a
   managed `usr`, `by` is a live enrolled key of that person in the op's own closure. A person
   counts toward the quorum if, in addition, they are an admin person in the op's closure at its
   `iat`. A person's later removal of a device does not reach back into the roster.
3. **Authority.** An authority-key op is authorised. Any other op is authorised iff its primary
   signature counts. A **self-remove** (a `remove` whose `mem` is the signer's own `usr`) needs
   only a valid signature. `reset` and `resolve` are authority-key only. Otherwise
   `unauthorised`.
4. **Quorum.** A non-authority op needs `k = min(2, max(H, 1))` distinct counted admin persons,
   where `H` is the number of distinct persons ever set to admin or owner among the ops the op
   does not precede. If `H ≤ 1` the sole admin must sign with **two distinct keys**. Otherwise
   `under_threshold`. Self-removes bypass the quorum, but the **last owner** cannot leave
   (`last_owner`).
5. **Concurrency: least privilege.** An effective authority-key reduction of a person voids
   that person's signature on every concurrent op; an effective quorum reduction (or an admin's
   self-remove) voids it on every concurrent **grant**. An op left short of `k` is `outranked`.
6. **Resolution.** A person's role is the **minimum** over the frontier of their effective
   `set`/`remove` ops (a `remove`, or a `set` whose `exp ≤ now`, counts as ⊥). A later op that
   cites the whole frontier settles a fork. Managed keys resolve the same way per `(mem, key)`
   over `enrol`/`unenrol`; a key is usable only while its person is on the roster and its
   `enrol` has not expired.
7. **History cap.** At most 10,000 roster ops are evaluated, with the same anchored-history rule
   as membership.

The view reports each person's kind, role and (managed) live keys, the roster heads, the current
authority key and the moment it took over, whether the org is **frozen**, and per-op verdicts.

## Re-roots

A `reroot` moves the authority key to `succ` (`examples/roster-op-reroot-body.json`):

- `by` is the authority key in force in the op's closure;
- `succ` is a fresh genesis key from a new recovery secret, and `succsig` is `succ`'s Ed25519
  signature over `"void-which-binds-roster-reroot-v1\x00" ‖ core`, proving its holder took part;
- `cosig` carries an admin quorum counting only admins **independent** of `by`: persons whose
  admin grant traces back to the pinned founding op, to an earlier authority key, or to a quorum
  of admins themselves independent of `by`. Appointees of the retiring key never count.

Once a re-root applies, ops by the old key outside its closure are `retired_authority`, and ops
by the new key must cite it. Two eligible re-roots of the same key that do not cite each other
**freeze** the org (`reroot_conflict`): every RP that sees both refuses all requests for the
org and alerts, until a `resolve` signed by that key (citing every conflicting re-root, naming
one in `pick`) settles it. The org id never changes, so RPs follow a re-root by evaluating the
roster; nothing is re-pinned.

## How a relying party trusts persons through a roster

An RP (or the org's broker) **pins an org** as its id plus the founding op token, received out
of band. Pinning MUST refuse a founding op that is not an org-id-signed owner `set` with
`prev = []`.

### Headers

```
Authorization: Device <credential>~<possession>
Void-Which-Binds-Org: <org id>
Void-Which-Binds-Roster: <roster op>,<roster op>,…     (optional, at most 16, each budgeted at 4 KiB)
Void-Which-Binds-Membership: <person op>,…              (optional, at most 64; any usr)
```

- `Void-Which-Binds-Org` names exactly one org. It **selects the path**: a request that carries
  it is judged only by the org's roster, and one without it only by the RP's direct person pins.
  A failure on one path MUST NOT fall back to the other (no confused deputy).
- Any authenticated roster person may present roster ops; they are self-authenticating.
  Cosigners' person ops ride in the membership header, routed by `usr`.
- JSON-body routes (approvals) carry the same op sets as `ops` and `roster` arrays.

### The verifier path

1. The org must be pinned (`unknown_org`) and its view not frozen (`org_frozen`).
2. **Sovereign person**: the credential is the person's device add. The person must hold a role
   on the roster (`not_on_roster`, `removed`), and the device must be a current member of the
   person's membership log, evaluated at `now` over the RP's log ∪ presented ops. A device the
   person removed stops authenticating at every RP that has learned the remove.
3. **Managed person**: the credential is the roster `enrol` op that admitted the key; the key
   must be live for that `mp:` person in the same evaluation.
4. Nothing is written yet. The caller verifies possession (a possession proof for an `ed25519:`
   key; a passkey makes none and is accepted only by the flows that verify a passkey assertion,
   such as approvals and delegations, otherwise `unsupported_key`), and only then commits the
   fresh roster and person ops.

The authenticated principal carries the org id, the person id, the person kind, the role and the
roster heads, so the RP needs no second lookup for the role. For a managed person the person id
is the `mp:` id and there is no person key.

What is recorded: only through commit, after possession, for a person on the roster in that same
evaluation; ineffective ops too (they may be cited). The one exception is a **freeze**: an RP
records conflicting re-roots and their closures even without an authenticated caller, so that a
later request that omits them cannot authenticate.

A roster does not make anyone a grant issuer: being on a roster, even as owner, never lets a key
issue capability grants ([grants.md](grants.md)). **Unpinning** an org refuses every org-path
request whatever its roster says.

### Roster push

**Status: draft.** The broker is expected to push roster heads to the RPs it fronts, so that a
removal, an expiry-extending grant, a re-root or a conflict reaches an RP before a member happens
to present it. The RP evaluates pushed ops before recording them and accepts them only over a
channel on which it authenticates the broker. This is a deployment duty, not yet a specified or
built route.

## The enrolment proof

Before a broker drafts an `enrol` for a managed person's new key, the invitee proves possession
of the candidate key over:

```
frame("void-which-binds/roster/enrol-proof/v1") ‖ frame(audience) ‖ frame(org) ‖ frame(mem)
‖ frame(key) ‖ frame(nonce) ‖ frame(uint64_be(iat)) ‖ frame(uint64_be(exp))
```

`audience` is the broker's origin, `mem` the `mp:` id, `key` the candidate (`ed25519:` or
`webauthn:es256:`), `nonce` 32 broker-issued bytes for this invite and key, single use, and
`exp − iat` at most 2 minutes. An `ed25519:` candidate signs it directly; a passkey asserts over
the WebAuthn challenge derived from it ([grants.md](grants.md#the-webauthn-member-key)). The
broker's invite routes that carry it are not specified here.

## Security considerations

- Every roster change except leaving needs two admin persons (or two keys of a sole admin), so
  one stolen device cannot change the roster.
- Least privilege under concurrency means a race can only lose privilege, never gain it.
- Re-roots need both halves of the org's authority: the current key and independent admins.
- Pin the founding op, not just the org id, or a holder of the org secret could mint a second
  founding op.
- RPs MUST refuse a frozen org and alert an operator rather than pick a side.
