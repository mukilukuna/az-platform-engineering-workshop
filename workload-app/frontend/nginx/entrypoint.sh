#!/bin/sh
set -e

# Substitute environment variables in nginx config template
# BACKEND_URL should be provided as environment variable (e.g., http://backend.internal)
envsubst '${BACKEND_URL}' < /etc/nginx/conf.d/default.conf.template > /etc/nginx/conf.d/default.conf

# Validate nginx configuration
nginx -t

# Start nginx in foreground
exec nginx -g "daemon off;"
