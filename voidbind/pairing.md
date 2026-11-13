# Pairing

**Status: stable.** Go core `pairing` (commitment and SAS), `pairflow` (the two-sided flow,
invite and refusal) and `relay`; ported byte for byte by the Kotlin device library, whose
`Invite.encode` is identical to the Go encoder.

A new device is never given a secret. It generates its own keys, and an existing **member
device** (the **initiator**) signs a membership `add` for them ([identity.md](identity.md)). The
two devices talk through an untrusted **relay**, and a human compares a 7-digit **short
authentication string** (SAS) on both screens before anything is signed. The new device is the
**responder**.

The initiator is normally a member device. It may instead be **genesis**, derived for this one
pairing from the recovery secret and then dropped: for the first device of an identity, or to
re-admit a device a member removed (only genesis can).

## The relay

A dumb, write-once, opaque blob store. It never parses a payload, holds no key and runs no
crypto. Everything it carries is either public (commitments, public keys, signed ops) or
ciphertext it cannot open.

| Request | Response |
| --- | --- |
| `POST /v1/sessions` | `200 {"session_id": "<32 lowercase hex>"}` (`examples/relay-create-session-response.json`); `503` at the session cap |
| `PUT /v1/sessions/{id}/{role}/{type}`, body = the opaque message | `204`; `400` bad role or type; `404` unknown session; `409` slot already written; `413` message too large |
| `GET /v1/sessions/{id}/{role}/{type}` | `200` with the stored bytes; `404` unknown session or not yet written |

- `role` is `initiator` or `responder`. Each side **writes its own role's slots** and reads the
  peer's.
- `type` for pairing is one of `commit`, `reveal`, `cert`, `refuse`. A relay without `refuse`
  answers `400` for it; an initiator then cannot refuse, and the responder times out as before.
- Slots are **write-once**. This is not the security boundary (the commitments are) but stops a
  participant replacing its own commitment after the peer has read it.
- Bounds in the reference relay: 64 KiB per message, 1024 live sessions, idle sessions evicted
  after 10 minutes, 128-bit unguessable session ids. Clients poll `GET` (150 ms in the reference
  client) until a slot appears.

The relay is also reused, with the slot types `proposal` and `cosig` and a 512 KiB message cap,
to carry roster cosignature requests between admins; that transport is not specified here.

## The invite

The initiator creates a session and shows the invite as a QR code (or text the user pastes). The
**visual channel** is what authenticates the relay origin, the session, the salt and the
identity: a network attacker cannot substitute them without also defeating the SAS.

```
void-which-binds:pair?relay=<relay base>&salt=<hex>&session=<id>&usr=<ed25519 key>&v=4
```

(`examples/pair-invite.json`.) The query is standard `application/x-www-form-urlencoded`; the
reference encoder sorts the keys.

| Param | Meaning | Rule |
| --- | --- | --- |
| `v` | invite version | MUST be `4`; anything else is refused |
| `relay` | the relay base URL (the `/v1/sessions` routes hang off it) | required |
| `session` | the relay session id | required |
| `salt` | a fresh per-pairing salt, **hex** | at least 16 bytes; the reference draws 32 |
| `usr` | the identity the new device joins | a canonical `ed25519:` key |

A responder MUST refuse a different scheme or opaque part (`void-which-binds:` and `pair`), a
missing field, a short salt or a non-canonical `usr`.

## The handshake

Both sides run the same steps. The ordering is the security: **commit before reveal**, and
**open before trust**.

1. **Commit.** Each side computes a commitment to both its public keys and writes the raw
   32 bytes to its `commit` slot, then **waits for the peer's commitment before revealing
   anything**:

   ```
   commit = SHA-256( frame("void-which-binds/pairing/commit/v2") ‖ frame(sign) ‖ frame(enc) )
   ```

   `sign` is the 32-byte Ed25519 key, `enc` the 32-byte X25519 key (empty for a genesis
   initiator, still framed). `frame(p) = uint64_be(len(p)) ‖ p`.

2. **Reveal.** Each side writes its keys to its `reveal` slot as JSON and reads the peer's
   (`examples/pair-reveal-initiator.json`, `examples/pair-reveal-responder.json`):

   | Member | Type | Req. | Meaning |
   | --- | --- | --- | --- |
   | `sign` | key | yes | the side's `ed25519:` signing key (genesis, for a genesis initiator) |
   | `enc` | key | responder: yes; member initiator: yes; genesis initiator: absent | the side's `x25519:` key |
   | `ops` | array of op token | initiator only | the initiator's membership replica: every op it knows for `usr` |

   Each side then **opens** the peer's commitment against the revealed keys and aborts on a
   mismatch.

3. **Membership gate (responder).** If the initiator's `sign` is not `usr` itself, the responder
   evaluates the revealed `ops` under `usr` and requires the initiator to be a current member,
   and to have revealed an encryption key, **before deriving the SAS**. A non-member never gets a
   string to compare.

4. **SAS.** Both sides derive:

   ```
   d   = SHA-256( frame("void-which-binds/pairing/sas/v2")
                  ‖ frame(initiator.sign) ‖ frame(initiator.enc)
                  ‖ frame(responder.sign) ‖ frame(responder.enc)
                  ‖ frame(salt) )
   SAS = (d as a 256-bit big-endian integer) mod 10^7, as 7 decimal digits with leading zeros
   ```

   The roles fix the order. Substituting any key, in either role, changes the string. Display it
   grouped `NNN NNNN`; compare the raw digits. The human confirms the two screens match. The
   SAS **is** the security: an implementation MUST NOT skip the comparison outside tests.

## The admission

After a human confirms the match, the initiator:

1. signs `add{usr, dev: responder.sign, denc: responder.enc, by: itself, prev: its heads}`
   ([identity.md](identity.md#membership-ops));
2. builds the plaintext **admission** `{"op": <that add>, "ops": <its replica, plus the add>}`
   (`examples/pair-admission.json`);
3. draws a fresh random 32-byte key `k`, **seals** `k` to the responder's X25519 key and encrypts
   the admission under `k`;
4. writes `{"wrapped": <base64url>, "cipher": <base64url>}` to its `cert` slot
   (`examples/pair-sealed-cert.json`).

The seal (ephemeral-static ECDH; the recovery spec describes the same construction for space
keys):

```
e, E    = fresh X25519 key pair
shared  = X25519(e, R)                  R = the responder's encryption key
key     = HKDF-SHA256(ikm = shared, salt = E ‖ R, info = "void-which-binds/space-key-wrap/v1", len 32)
wrapped = E ‖ nonce(24) ‖ XChaCha20-Poly1305(key, nonce, k, aad = E ‖ R)        (104 bytes)
cipher  = nonce(24) ‖ XChaCha20-Poly1305(k, nonce, admission JSON, aad = none)
```

The responder unwraps and decrypts, then MUST check, refusing the admission otherwise:

- the op verifies, is an `add` for `usr`, is signed by **the initiator key bound in its SAS**,
  and admits **its own** signing key with **its own** encryption key;
- evaluating `usr` over the initiator's revealed ops ∪ the admission's ops ∪ the add leaves the
  add neither rejected nor ineffective, and the responder a current member.

It then stores the add as its credential and the ops as its replica.

## Refusal

When the human says the strings differ, or cancels, the initiator posts a signed **refusal** to
its own `refuse` slot instead of a cert (`examples/pair-refusal-body.json`):

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `v` | int | yes | 1 |
| `typ` | string | yes | `void-which-binds.pair-refusal` |
| `by` | key | yes | the initiator's signing key (a member device's, or genesis's); also the signer |
| `ses` | base64url | yes | `SHA-256("void-which-binds/pairflow/refusal/session/v1" ‖ 0x00 ‖ salt)` |

There is no `iat`/`exp`: the session binding confines a refusal to one pairing.

The responder waits on `cert` and `refuse` at once, from the end of its handshake. It honours a
refusal only if it verifies under the initiator key bound in its SAS, `typ` and `v` are exact,
`by` equals that key, and `ses` equals the binding of **its own** salt. It then stops and
reports that the other device refused; nothing was admitted. **Anything else in the slot is
ignored** and the responder keeps waiting for the cert: a forged refusal cannot end a pairing
early or be reported as the other device's decision. An initiator that has posted a cert never
refuses, and one that has refused never posts a cert.

## Errors

The relay's HTTP codes are above. The flow itself has no wire errors: each side aborts locally
and reports why (commitment mismatch, non-member initiator, an admission that does not verify,
a refusal, a timeout). A responder MUST NOT enrol on any failure.

## Security considerations

- **Commit before reveal** closes the rushing attack: a relay that sees one side's keys before
  committing could choose keys whose SAS collides. Both keys of each device are committed, so
  the encryption key cannot be swapped either.
- The SAS is 7 digits (about 23 bits) against **one online guess** per pairing; the salt is
  fresh, so nothing can be precomputed.
- The membership gate means a stranger who scans someone's invite gets no string to compare.
- The relay sees only public values and ciphertext. It can deny service (drop or occupy slots)
  but cannot enrol a device or read the admission.

## Code and documentation notes

- ADR-0002 shows the invite as `voidbind:pair?v=2&relay=…&session=…&salt=…`. That is the
  retired gen1 shape; the code emits `void-which-binds:pair?…&usr=…&v=4` and refuses the old
  one.
