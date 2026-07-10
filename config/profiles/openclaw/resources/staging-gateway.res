# config/profiles/openclaw/resources/staging-gateway.res — a profile shared-resource descriptor.
# Sourced (plain KEY=VALUE) by the yard registry (scripts/lib-resources.sh). The MECHANICS live
# in HANDLER (scripts/project-staging.sh); the core only consults this descriptor.
COMMAND=staging
HANDLER=project-staging.sh
TITLE="Live staging gateway zone (isolated from prod)"
VERBS="up start stop status logs shell down destroy list e2e"
BRINGUP=start
SHUTDOWN=stop
