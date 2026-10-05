#!/usr/bin/env bash

# Publish Photo Weaver to GitHub Pages and connect a Cloudflare-managed domain.
#
# Usage:
#   ./deploy.sh
#
# Optional overrides:
#   GITHUB_OWNER=hashb GITHUB_REPO=photo-weaver \
#   CUSTOM_DOMAIN=weave.chenna.me CLOUDFLARE_ZONE=chenna.me ./deploy.sh
#
# The Cloudflare token needs Zone:Read and DNS:Edit for chenna.me. It is read
# from CLOUDFLARE_API_TOKEN or requested securely and is never written to disk.

set -euo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-hashb}"
GITHUB_REPO="${GITHUB_REPO:-photo-weaver}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-weave.chenna.me}"
CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE:-chenna.me}"
REPO_VISIBILITY="${REPO_VISIBILITY:-public}"
FULL_REPO="${GITHUB_OWNER}/${GITHUB_REPO}"
PAGES_HOST="${GITHUB_OWNER}.github.io"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() {
  printf '\n\033[1;34m→\033[0m %s\n' "$*"
}

ok() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31mError:\033[0m %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need git
need gh
need curl
need python3

cd "$ROOT_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run this inside the Photo Weaver Git repository."

say "Checking GitHub authentication"
if ! gh auth status -h github.com >/dev/null 2>&1; then
  printf 'GitHub CLI needs authentication. A browser login will open now.\n'
  gh auth login -h github.com -p https -w
fi

ACTIVE_GITHUB_USER="$(gh api user --jq .login)"
if [[ "$ACTIVE_GITHUB_USER" != "$GITHUB_OWNER" ]]; then
  die "GitHub CLI is authenticated as ${ACTIVE_GITHUB_USER}, not ${GITHUB_OWNER}."
fi
ok "Authenticated as ${ACTIVE_GITHUB_USER}"

say "Preparing the repository"
printf '%s\n' "$CUSTOM_DOMAIN" > CNAME

if [[ -z "$(git config --get user.name || true)" ]]; then
  git config user.name "$(gh api user --jq '.name // .login')"
fi
if [[ -z "$(git config --get user.email || true)" ]]; then
  GITHUB_USER_ID="$(gh api user --jq .id)"
  git config user.email "${GITHUB_USER_ID}+${GITHUB_OWNER}@users.noreply.github.com"
fi

git branch -M main
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Publish Photo Weaver"
  ok "Committed the current site"
else
  ok "Working tree is already committed"
fi

if gh repo view "$FULL_REPO" >/dev/null 2>&1; then
  ok "GitHub repository ${FULL_REPO} already exists"
else
  case "$REPO_VISIBILITY" in
    public) gh repo create "$FULL_REPO" --public --description "A playful photo weaving studio" ;;
    private) gh repo create "$FULL_REPO" --private --description "A playful photo weaving studio" ;;
    *) die "REPO_VISIBILITY must be public or private." ;;
  esac
  ok "Created ${FULL_REPO}"
fi

EXPECTED_REMOTE="https://github.com/${FULL_REPO}.git"
if git remote get-url origin >/dev/null 2>&1; then
  CURRENT_REMOTE="$(git remote get-url origin)"
  case "$CURRENT_REMOTE" in
    "https://github.com/${FULL_REPO}"|"https://github.com/${FULL_REPO}.git"|"git@github.com:${FULL_REPO}.git") ;;
    *) die "The existing origin points to ${CURRENT_REMOTE}, not ${FULL_REPO}." ;;
  esac
else
  git remote add origin "$EXPECTED_REMOTE"
fi

git push -u origin main
ok "Pushed main to GitHub"

say "Enabling GitHub Pages"
if gh api "repos/${FULL_REPO}/pages" >/dev/null 2>&1; then
  gh api -X PUT "repos/${FULL_REPO}/pages" \
    -f 'source[branch]=main' \
    -f 'source[path]=/' >/dev/null
else
  gh api -X POST "repos/${FULL_REPO}/pages" \
    -f 'source[branch]=main' \
    -f 'source[path]=/' >/dev/null
fi
ok "GitHub Pages is building from main:/"

say "Configuring Cloudflare DNS"
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  read -r -s -p "Cloudflare API token (Zone:Read + DNS:Edit): " CLOUDFLARE_API_TOKEN
  printf '\n'
fi
[[ -n "$CLOUDFLARE_API_TOKEN" ]] || die "A Cloudflare API token is required."

CF_AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
ZONE_RESPONSE="$(curl -fsS \
  -H "$CF_AUTH_HEADER" \
  -H 'Content-Type: application/json' \
  "https://api.cloudflare.com/client/v4/zones?name=${CLOUDFLARE_ZONE}&status=active")"

ZONE_ID="$(printf '%s' "$ZONE_RESPONSE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("success") or len(d.get("result", [])) != 1:
    print("Cloudflare zone lookup failed or returned multiple zones.", file=sys.stderr)
    raise SystemExit(1)
print(d["result"][0]["id"])
')" || die "Could not find the active Cloudflare zone ${CLOUDFLARE_ZONE}."
ok "Found Cloudflare zone ${CLOUDFLARE_ZONE}"

RECORDS_RESPONSE="$(curl -fsS \
  -H "$CF_AUTH_HEADER" \
  -H 'Content-Type: application/json' \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${CUSTOM_DOMAIN}")"

RECORD_INFO="$(printf '%s' "$RECORDS_RESPONSE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("success"):
    print("Cloudflare DNS lookup failed.", file=sys.stderr)
    raise SystemExit(1)
records = d.get("result", [])
cnames = [r for r in records if r.get("type") == "CNAME"]
others = [r for r in records if r.get("type") != "CNAME"]
if others:
    print("CONFLICT\t" + ",".join(sorted({r.get("type", "unknown") for r in others})))
elif cnames:
    print("CNAME\t" + cnames[0]["id"])
else:
    print("NONE\t")
')" || die "Could not inspect the existing DNS record."

RECORD_STATE="${RECORD_INFO%%$'\t'*}"
RECORD_ID="${RECORD_INFO#*$'\t'}"
if [[ "$RECORD_STATE" == "CONFLICT" ]]; then
  die "${CUSTOM_DOMAIN} already has a non-CNAME DNS record (${RECORD_ID}). Remove or rename it, then rerun."
fi

DNS_PAYLOAD="$(python3 - "$CUSTOM_DOMAIN" "$PAGES_HOST" <<'PY'
import json, sys
print(json.dumps({
    "type": "CNAME",
    "name": sys.argv[1],
    "content": sys.argv[2],
    "ttl": 1,
    "proxied": False,
    "comment": "GitHub Pages: Photo Weaver",
}))
PY
)"

if [[ "$RECORD_STATE" == "CNAME" ]]; then
  DNS_RESPONSE="$(curl -fsS -X PATCH \
    -H "$CF_AUTH_HEADER" \
    -H 'Content-Type: application/json' \
    --data "$DNS_PAYLOAD" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}")"
else
  DNS_RESPONSE="$(curl -fsS -X POST \
    -H "$CF_AUTH_HEADER" \
    -H 'Content-Type: application/json' \
    --data "$DNS_PAYLOAD" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records")"
fi

printf '%s' "$DNS_RESPONSE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("success"):
    print(json.dumps(d.get("errors", []), indent=2), file=sys.stderr)
    raise SystemExit(1)
' || die "Cloudflare rejected the DNS update."
ok "${CUSTOM_DOMAIN} now points to ${PAGES_HOST} (DNS only)"

say "Attaching the custom domain to GitHub Pages"
gh api -X PUT "repos/${FULL_REPO}/pages" -f "cname=${CUSTOM_DOMAIN}" >/dev/null
ok "GitHub Pages custom domain is ${CUSTOM_DOMAIN}"

say "Waiting for deployment and HTTPS"
LIVE=0
for ATTEMPT in $(seq 1 30); do
  PAGE_STATUS="$(gh api "repos/${FULL_REPO}/pages" --jq '.status // "unknown"' 2>/dev/null || printf 'unknown')"
  HTTP_CODE="$(curl -L -sS --max-time 15 -o /dev/null -w '%{http_code}' "https://${CUSTOM_DOMAIN}" 2>/dev/null || true)"
  printf '  attempt %02d/30 · Pages: %-8s · HTTPS: %s\n' "$ATTEMPT" "$PAGE_STATUS" "${HTTP_CODE:-pending}"
  if [[ "$HTTP_CODE" == "200" ]]; then
    LIVE=1
    break
  fi
  sleep 10
done

if gh api -X PUT "repos/${FULL_REPO}/pages" -F https_enforced=true >/dev/null 2>&1; then
  ok "HTTPS enforcement enabled"
else
  printf 'HTTPS enforcement is not available yet; GitHub will finish provisioning the certificate shortly.\n'
fi

printf '\nRepository: https://github.com/%s\n' "$FULL_REPO"
printf 'Site:       https://%s\n' "$CUSTOM_DOMAIN"
if [[ "$LIVE" == "1" ]]; then
  ok "Deployment is live"
else
  printf 'The configuration is complete, but DNS or the TLS certificate is still propagating.\n'
  printf 'Rerun this script later, or check: gh api repos/%s/pages\n' "$FULL_REPO"
fi
