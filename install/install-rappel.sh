#!/bin/bash
set -euo pipefail

git clone --depth 1 https://github.com/yrp604/rappel.git /tmp/rappel
make -C /tmp/rappel
cp /tmp/rappel/bin/rappel /usr/local/bin/rappel
rm -rf /tmp/rappel
