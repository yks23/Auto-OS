#!/usr/bin/env bash
exec python3 "$(dirname "$0")/tail-http-serve.py" "$@"
