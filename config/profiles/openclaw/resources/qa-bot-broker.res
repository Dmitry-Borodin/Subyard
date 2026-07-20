# config/profiles/openclaw/resources/qa-bot-broker.res — a profile shared-resource descriptor.
# Sourced (plain KEY=VALUE) by the yard registry (scripts/lib-resources.sh). The mechanics live
# in the profile-owned handler directory; the core only consults this descriptor.
COMMAND=qa-pool
HANDLER=resources/qa-bot-broker/handler.sh
TITLE="QA bot pool (in-yard credential broker)"
VERBS="up seed expose status logs smoke down destroy"
BRINGUP=up
SHUTDOWN=down
