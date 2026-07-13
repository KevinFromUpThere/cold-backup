# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file PowerShell script (`cold-backup.ps1`) that manages cold backups of a large media library (~42,000 files) onto a rotating set of retired hard drives. It maintains a SQLite index (`%USERPROFILE%\cold-backup\backup-index.db`) that tracks every source file and, once archived, which physical `OFFLINE_XX` drive it landed on. The index lives on the local machine, not on the backup drives, so a dead drive doesn't take the records with it.

## Running the script

There is no build step, package manifest, or test suite — it's a standalone `.ps1` invoked directly:

```powershell
.\cold-backup.ps1 scan              # Index all source libraries
.\cold-backup.ps1 backup            # Copy unarchived files to connected OFFLINE_ drives
.\cold-backup.ps1 status            # Show backup progress by type
.\cold-backup.ps1 search "Avatar"   # Find a file and see which drive it's on
.\cold-backup.ps1 drives            # List connected OFFLINE_ drives with fill bar
.\cold-backup.ps1 init-drive G:     # Format and label a blank drive (destructive)
.\cold-backup.ps1 verify            # Confirm archived files still exist on drives (size check)
.\cold-backup.ps1 verify full        # Same, plus SHA-256 hash comparison against the checksum recorded at backup time
```

The [PSSQLite](https://github.com/RamblingCookieMonster/PSSQLite) module is required and self-installs (`Install-Module PSSQLite -Scope CurrentUser`) on first run via `Require-PSSQLite`.

There's no automated test harness — verifying a change means running the relevant subcommand against real (or a scratch) SQLite DB and drive letters, per the project's `verify` skill philosophy.

## Architecture

Everything lives in one script, organized into clearly delimited regions (`# ── Section ───`) each holding one function per subcommand. `param()` at the top dispatches `$Command` to a handler via the `switch` at the bottom (`Entry point`).

Key structural points:

- **Configuration block** (top of file): `$script:DbPath`, `$script:DrivePrefix`, `$script:BufferBytes`, and `$script:Libraries` (the list of source paths/types/labels to scan) are hardcoded here — this is the only "config file" the script has. Changing source drive letters or adding/removing libraries means editing this array directly.
- **`files` table**: one row per source file, keyed by `source_path`. Tracks `archived` status, and once backed up, `drive_label` / `drive_path` / `archived_at` / `checksum`. Also carries metadata parsed at scan time for querying/reporting: `show_name` / `season_number` (TV only, parsed from the source path), `container` (file extension), `resolution` (parsed from the filename, e.g. `1080p`/`2160p`), plus `last_verified_at` / `verify_status` written by `verify`. All the parsed fields are best-effort — `NULL` when nothing matched — since they come from filename/path conventions, not a media prober.
- **`drives` table**: one row per physical `OFFLINE_XX` drive ever used, tracking the last-seen drive letter and first/last-used timestamps. Drive *labels* (`OFFLINE_07`, etc.) are the stable identity; drive *letters* (`G:`) are transient and re-read from `Get-Volume` each run since Windows reassigns them.
- **`Get-TVShowInfo` / `Get-Resolution`**: filename/path parsing helpers used only during `scan`. Show name is the first path segment under the library root; season number comes from a `Season NN` path segment or falls back to an `SxxEyy` filename pattern. Resolution is matched from common tags in the filename (`4k` normalizes to `2160p`). No `ffprobe`/media-inspection dependency — keeps `scan` fast across ~42k files.
- **`Invoke-Scan`**: the only function that needs a persistent `New-SQLiteConnection` (rather than the one-shot `Invoke-SqliteQuery -DataSource`) because it batches inserts inside explicit `BEGIN/COMMIT` transactions (500 files at a time) for throughput across tens of thousands of files. Every other function uses `-DataSource`, which opens/closes a connection per call.
- **`Start-Backup`**: iterates connected `OFFLINE_*` drives (detected via `Get-OfflineDrives`, matched by volume label, not letter), and for each drive re-queries `WHERE archived = 0` *per drive* so files archived earlier in the same run are excluded. Free space is rechecked before every single file copy (`Get-Volume` + `$script:BufferBytes` margin) since large media files make per-file space checks cheap relative to the risk of overfilling a drive. Destination layout mirrors the source library's relative path under a `<DriveLetter>\<Type>\` root. After each copy it computes a SHA-256 of the destination file and stores it as `checksum` — this is a second full read of the file (on top of the copy), so it materially adds to backup time, but it's what makes `verify full` meaningful later. A hashing failure is treated the same as a copy failure (file is not marked `archived`).
- **`Initialize-BackupDrive`** (`init-drive`): destructive — formats a drive as NTFS. It computes the next sequential `OFFLINE_NN` label by taking the max across *both* currently-connected drive labels and labels already in the `drives` table (so a label isn't reused even if that drive isn't currently plugged in), then requires the user to type the exact proposed label back as a confirmation prompt before formatting.
- **`Invoke-Verify`**: only checks files whose `drive_label` matches a currently-connected drive. Default mode is still the fast sanity check (existence + size against the DB's recorded `size_bytes`); `verify full` additionally recomputes the SHA-256 and compares it to the stored `checksum` — slower since it rereads every file, meant for occasional deep checks rather than routine use. Every run persists `last_verified_at` / `verify_status` per file regardless of mode, so integrity drift is visible across repeated runs over the drives' lifetime.

## Working on this script

- Drive identity is always the volume **label** (`OFFLINE_XX`), never the letter — letters are reassigned by Windows between sessions/reboots and must never be persisted as a durable key.
- `source_path` has a `UNIQUE` constraint and scanning uses `INSERT OR IGNORE`, so re-running `scan` is always safe/idempotent.
- Any change touching `Start-Backup` or `init-drive` involves data-destructive or physically-irreversible operations (overwriting drive contents, formatting) — be conservative and preserve the existing confirmation/guard patterns.
