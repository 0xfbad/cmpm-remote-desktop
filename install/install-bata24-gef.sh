#!/bin/bash
set -euo pipefail

KEYSTONE_SHA256=5a5316a34323620b1bba31dcfe9e4b4ca6f0c030e82fc7a151da7c8fbe81a379
KEYSTONE_WHEEL=/tmp/keystone_engine-0.9.2-py2.py3-none-manylinux1_x86_64.whl
curl --proto '=https' --tlsv1.2 -fsSL \
  https://files.pythonhosted.org/packages/01/5c/40ffbec589262f49ff7c463d96ff0bfab0fbd98d9d869c370a70853a13fb/keystone_engine-0.9.2-py2.py3-none-manylinux1_x86_64.whl \
  -o "$KEYSTONE_WHEEL"
echo "$KEYSTONE_SHA256  $KEYSTONE_WHEEL" | sha256sum -c -
pip install --break-system-packages --no-deps "$KEYSTONE_WHEEL"
rm "$KEYSTONE_WHEEL"

mkdir -p /opt/bata24-gef
GEF_COMMIT=dfaf6ca6e59962a1ceaac922dab5efc43b38ccd8
GEF_SHA256=132902dfb2ffc0ba629a41fe8eef8cb046d8d3925c84c012990fab00d3d091f5
curl --proto '=https' --tlsv1.2 -fsSL \
  "https://raw.githubusercontent.com/bata24/gef/${GEF_COMMIT}/gef.py" \
  -o /opt/bata24-gef/gef.py
echo "$GEF_SHA256  /opt/bata24-gef/gef.py" | sha256sum -c -

cat >/usr/local/bin/bata24-gef <<'EOF'
#!/bin/sh
exec gdb -q -x /opt/bata24-gef/gef.py "$@"
EOF
chmod +x /usr/local/bin/bata24-gef
