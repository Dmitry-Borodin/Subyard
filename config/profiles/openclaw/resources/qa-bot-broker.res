# config/profiles/openclaw/resources/qa-bot-broker.res — a profile shared-resource descriptor.
# Sourced (plain KEY=VALUE) by the yard registry (scripts/lib-resources.sh). The MECHANICS live
# in HANDLER (scripts/qa-pool.sh); the core only consults this descriptor.
COMMAND=qa-pool
HANDLER=qa-pool.sh
TITLE="QA bot pool (in-yard credential broker)"
VERBS="up seed expose status logs smoke down destroy"
BRINGUP=up
SHUTDOWN=down
