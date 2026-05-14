# Stale cold-mirror DB

The DuckDB file `tracker.duckdb.cold-mirror-2026-05-07` is **not the live marginalia database**. It is a frozen point-in-time snapshot from 2026-05-07. The live, authoritative marginalia database is on the MacMini.

## How to reach the live DB

API: `http://andrews-mac-mini:3100` (when Tailscale is healthy)
Fallback during Tailscale outages: `http://andrews-mac-mini.local:3100` (mDNS)

## What changed

Around 2026-05-09 the canonical marginalia instance moved from MBP to MacMini. Until then, this file *was* the live DB on the canonical machine. After the move, it's a stale snapshot kept for disaster-recovery purposes only.

## Do not

- Query this file directly with `duckdb`, `python`, or any other client. Anything you read will be at best 7+ days out of date and at worst actively wrong if rows have been added, deleted, or migrated since.
- Restore from this file to recreate a local marginalia. If you want to bring marginalia up on MBP, sync from MacMini first.

## Renaming back

If MacMini dies and MBP needs to become canonical again:

```
mv tracker.duckdb.cold-mirror-2026-05-07 tracker.duckdb
```

…but only after deciding that this snapshot is the recovery point you want, vs. asking for a fresher sync from any other source.
