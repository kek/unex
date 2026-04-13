#!/bin/sh
PORT=${UNEX_PORT:-8005}
exec wget --spider --quiet "http://127.0.0.1:${PORT}/health"
