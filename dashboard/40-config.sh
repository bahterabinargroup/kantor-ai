#!/bin/sh
# Membuat config.js dari environment saat container start (hanya anon key, bukan service key).
cat > /usr/share/nginx/html/config.js <<EOF
window.KANTOR_CONFIG = {
  SUPABASE_URL: "${SUPABASE_URL}",
  SUPABASE_ANON_KEY: "${SUPABASE_ANON_KEY}"
};
EOF
