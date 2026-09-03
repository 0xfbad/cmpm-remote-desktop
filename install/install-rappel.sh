#!/bin/bash
set -euo pipefail

RAPPEL_COMMIT=981d8faf32b984e791841193498f46313fb6a56d
RAPPEL_SHA256=ae8b71c4a4ad6ede2a5700000d6fc6a7de39c2c361895628d1e03c1feee23ddd
RAPPEL_SOURCE=/tmp/rappel.tar.gz

curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --retry 5 --retry-all-errors \
  "https://github.com/yrp604/rappel/archive/${RAPPEL_COMMIT}.tar.gz" \
  -o "$RAPPEL_SOURCE"
echo "$RAPPEL_SHA256  $RAPPEL_SOURCE" | sha256sum -c -
mkdir -p /tmp/rappel
tar -xzf "$RAPPEL_SOURCE" -C /tmp/rappel --strip-components=1
make -C /tmp/rappel
cp /tmp/rappel/bin/rappel /usr/local/bin/rappel
rm -rf "$RAPPEL_SOURCE" /tmp/rappel
