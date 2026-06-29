# config/profiles/android/resources/emulator.res — a profile shared-resource descriptor.
# Sourced (plain KEY=VALUE) by the yard registry (scripts/lib-resources.sh). It declares how the
# yard core discovers/dispatches/probes this resource; the resource's MECHANICS live entirely in
# HANDLER (scripts/yard-emu.sh), which the core never has to know about.
COMMAND=emu
HANDLER=yard-emu.sh
TITLE="Android emulator (in the yard + host-facing adb/scrcpy bridge)"
VERBS="up stop status adb view tunnel down"
BRINGUP=up
