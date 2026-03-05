#!/bin/sh
# CI lint: ensure all AI request serialization goes through security/gateway.zig
#
# Direct calls to serializeXxxRequest from feature code bypass redaction.
# Only security/gateway.zig and overlay/ai_config.zig (definitions + tests) are allowed.

set -e

VIOLATIONS=0

# Functions that must only be called from the gateway
BANNED="serializeFixRequest\|serializeExplainRequest\|serializeGenerateRequest\|serializeRewriteRequest\|serializeRequest"

# Find direct imports/calls outside allowed files
HITS=$(grep -rn "$BANNED" src/ \
    --include='*.zig' \
    | grep -v 'src/security/gateway.zig' \
    | grep -v 'src/overlay/ai_config.zig' \
    | grep -v '// gateway-exempt' \
    || true)

if [ -n "$HITS" ]; then
    echo "ERROR: Direct AI serializer calls found outside security gateway!"
    echo ""
    echo "All AI requests must go through security/gateway.zig to ensure"
    echo "sensitive content is redacted before sending."
    echo ""
    echo "Violations:"
    echo "$HITS"
    echo ""
    echo "Fix: use security_gateway.prepareRequest() instead."
    VIOLATIONS=1
fi

# Also check for raw g_ai_request_body usage (old pattern)
OLD_PATTERN="g_ai_request_body"
OLD_HITS=$(grep -rn "$OLD_PATTERN" src/ \
    --include='*.zig' \
    || true)

if [ -n "$OLD_HITS" ]; then
    echo "ERROR: Found references to removed g_ai_request_body!"
    echo ""
    echo "Use g_ai_prepared_request (PreparedRequest) instead."
    echo ""
    echo "Violations:"
    echo "$OLD_HITS"
    VIOLATIONS=1
fi

if [ "$VIOLATIONS" -eq 0 ]; then
    echo "OK: All AI requests go through security gateway."
fi

exit $VIOLATIONS
