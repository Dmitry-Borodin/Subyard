# config/profiles/openclaw/resources/staging-gateway.res — a profile shared-resource descriptor.
# Sourced (plain KEY=VALUE) by the yard registry (scripts/lib-resources.sh). The mechanics live
# in the profile-owned handler directory; the core only consults this descriptor.
COMMAND=staging
HANDLER=resources/staging-gateway/handler.sh
TITLE="Live staging gateway zone (isolated from prod)"
VERBS="up start stop status logs shell down destroy list e2e"
BRINGUP=start
SHUTDOWN=stop
