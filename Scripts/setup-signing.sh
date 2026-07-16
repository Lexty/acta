#!/usr/bin/env bash
# One-time, non-interactive setup of a local self-signed code-signing identity for Acta.
#
# Why this exists. Ad-hoc signing (`codesign -s -`) pins an app's *designated requirement* to the
# binary's cdhash, so every rebuild changes it and macOS revokes the app's TCC grants (Screen
# Recording, Microphone) — you re-grant on every single build. Signing with a certificate instead
# gives a STABLE designated requirement (`identifier "…" and certificate leaf = H"…"`), so a rebuild
# keeps the grant. The certificate is self-signed and untrusted, which is fine here: the signature
# still validates and TCC binds to it; only Gatekeeper cares about an Apple anchor, and Gatekeeper
# does not gate a locally-built app you run yourself.
#
# Non-interactive by construction. No GUI, no login-keychain password: it creates a dedicated,
# empty-password keychain that holds only this certificate, and grants `codesign` access to the key
# via the partition list so signing never prompts. The private key is generated locally and never
# leaves the machine — nothing secret is committed. Idempotent: once the identity exists this is a
# no-op, so `bundle.sh` can call it freely.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/acta-codesign.keychain-db"
IDENTITY_CN="Acta Local Signing"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_CN"; then
  echo "==> signing identity already present — nothing to do"
  security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY_CN"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> generating a self-signed code-signing certificate"
cat > "$TMP/cfg.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $IDENTITY_CN
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cfg.cnf" >/dev/null 2>&1

# OpenSSL 3 writes a PKCS#12 MAC that Apple's Security framework rejects; `-legacy` selects the older
# algorithms it accepts. LibreSSL (the system openssl) has no such flag and already writes the older
# format, so only pass it when the openssl in PATH understands it.
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY="-legacy"; fi
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -name "$IDENTITY_CN" -passout pass:transit >/dev/null 2>&1

echo "==> creating a dedicated, empty-password keychain"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout, no lock on sleep
security unlock-keychain -p "" "$KEYCHAIN"

echo "==> importing the identity and granting codesign access without a prompt"
# `-P transit` is the throwaway transport password of the .p12, not a secret; `-T codesign` puts
# codesign on the key's ACL and `set-key-partition-list` completes it so no dialog ever appears.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "transit" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null

# codesign resolves an identity only from a keychain on the search list, so append this one (keeping
# login and anything already there). Idempotent — never added twice, never drops the others.
CURRENT="$(security list-keychains -d user | sed 's/"//g' | xargs)"
case " $CURRENT " in
  *" $KEYCHAIN "*) : ;;
  *) security list-keychains -d user -s $CURRENT "$KEYCHAIN" ;;
esac

echo "==> done — local signing identity ready"
security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY_CN"
