# No-op since the BGDB v1 port: ghosts.gdb is read with plain File I/O, so
# there are no GDNative DLLs to stage. Kept so the documented run sequence
# still works.
$ErrorActionPreference = "Stop"
Write-Host "OK: nothing to stage — the BGDB reader needs no native DLLs."
