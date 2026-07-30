# Orca is a yard-wide shared service, not a coding agent or project toolchain.
COMMAND=orca
HANDLER=resources/orca/handler.sh
TITLE="Orca remote server"
VERBS="up is-up status pair sync logs down"
BRINGUP=up
SHUTDOWN=down
