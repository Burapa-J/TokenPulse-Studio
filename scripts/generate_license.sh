#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <customer-email>"
    exit 1
fi

EMAIL="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

node -e '
import("./cloudflare-worker/polar-webhook.js").then(async (m) => {
  const req = new Request("https://worker.local/webhook", {
    method: "POST",
    body: JSON.stringify({ email: process.argv[1] })
  });
  const res = await m.default.fetch(req);
  console.log(await res.text());
});
' "${EMAIL}"
