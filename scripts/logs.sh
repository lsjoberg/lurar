#!/usr/bin/env bash
# Tail OSLog output for the Klang subsystem.
exec log stream --style compact --predicate 'subsystem == "se.linus.klang"' --info
