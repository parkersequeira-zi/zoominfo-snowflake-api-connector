#!/usr/bin/env bash
# Update the ZoomInfo connector secret to client-credentials shape.
# Reads credentials from env vars so the secret never appears in the command
# line, chat, or shell history. Run:  ZI_CLIENT_ID=... ZI_CLIENT_SECRET=... ./scripts/update_secret.sh
# (or export them first, then run the script).
set -euo pipefail

: "${ZI_CLIENT_ID:?Set ZI_CLIENT_ID (export ZI_CLIENT_ID=...)}"
: "${ZI_CLIENT_SECRET:?Set ZI_CLIENT_SECRET (export ZI_CLIENT_SECRET=...)}"

# Build the JSON body from env vars and SQL-escape it (double any single quotes,
# chr(39)), so a secret containing a quote can't break or inject into ALTER SECRET.
SECRET_JSON=$(ZI_CLIENT_ID="$ZI_CLIENT_ID" ZI_CLIENT_SECRET="$ZI_CLIENT_SECRET" python3 -c '
import json, os
body = json.dumps({"client_id": os.environ["ZI_CLIENT_ID"], "client_secret": os.environ["ZI_CLIENT_SECRET"]})
print(body.replace(chr(39), chr(39) * 2))
')

snow sql -c zoominfotest --role SCH_ZI_API_NATIVE_APP_DEV_PRODUCT_WRITE_ROLE -q "
ALTER SECRET DEV_PRODUCT.ZI_API_NATIVE_APP.ZI_OAUTH_CLIENT_SECRET
  SET SECRET_STRING = '${SECRET_JSON}';
"
echo "Secret updated."
