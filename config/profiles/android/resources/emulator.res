# config/profiles/android/resources/emulator.res — a profile shared-resource descriptor.
# Sourced (plain KEY=VALUE) by the yard registry (scripts/lib-resources.sh). It declares how the
# yard core discovers/dispatches/probes this resource; the resource's mechanics live entirely in
# its profile-owned handler directory, which the core never has to know about.
COMMAND=emu
HANDLER=resources/emulator/handler.sh
TITLE="Android emulator (in the yard; up/down include the host adb bridge)"
VERBS="up down status view"
BRINGUP=up
SHUTDOWN=down
