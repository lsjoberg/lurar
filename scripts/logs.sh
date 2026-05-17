#!/usr/bin/env bash
# Tail OSLog output for the Lurar subsystem.
exec log stream --style compact --predicate 'subsystem == "app.lurar.Lurar"' --info
