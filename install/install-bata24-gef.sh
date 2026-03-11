#!/bin/bash
set -e

pip install --break-system-packages keystone-engine unicorn capstone ropper

mkdir -p /opt/bata24-gef
curl -fLo /opt/bata24-gef/gef.py \
    https://raw.githubusercontent.com/bata24/gef/dev/gef.py

cat > /usr/local/bin/bata24-gef << 'EOF'
#!/bin/sh
exec gdb -q -x /opt/bata24-gef/gef.py "$@"
EOF
chmod +x /usr/local/bin/bata24-gef
