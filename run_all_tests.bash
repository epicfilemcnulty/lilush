#!/bin/bash
set -e

for f in tests/**/*.lua; do
    ./lilush "${f}"
done
