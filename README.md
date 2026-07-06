# cold-backup

A PowerShell script for rotating cold backups of large media libraries onto retired hard drives, using a SQLite index to track what's been archived and where.

## The problem

- ~42,000 media files across multiple drives (TV shows, movies, music)
- No NAS — just a pile of retired 3TB mechanical drives and a hot-swap cradle
- Need to know what's backed up, what isn't, and which physical drive a file lives on

## How it works

1. **Scan** — walks your source libraries and builds a SQLite index of every file
2. **Backup** — copies unarchived files to whatever `OFFLINE_XX` drives are currently inserted, filling each drive before moving to the next
3. **Swap** — eject the full drive, insert the next one, run backup again
4. **Search** — find any file and see which physical drive it's on

The index lives on your local machine (`%USERPROFILE%\cold-backup\backup-index.db`), not on the backup drives. Drive failures don't affect your records.

## Requirements

- Windows, PowerShell 5.1+
- [PSSQLite](https://github.com/RamblingCookieMonster/PSSQLite) — installed automatically on first run
- Source media libraries accessible as Windows drive letters (T:, H:, F:, E:)

## Setup

```powershell
# Clone or download, then run your first scan
.\cold-backup.ps1 scan
```

That's it. PSSQLite installs itself if missing (no admin required).

## Commands

```
.\cold-backup.ps1 scan              Index all source libraries
.\cold-backup.ps1 backup            Copy unarchived files to inserted drives
.\cold-backup.ps1 status            Show backup progress by type
.\cold-backup.ps1 search "Avatar"   Find a file and see which drive it's on
.\cold-backup.ps1 drives            List connected OFFLINE_ drives with fill bar
.\cold-backup.ps1 init-drive G:     Format and label a blank drive for use
.\cold-backup.ps1 verify            Confirm archived files still exist on drives
```

## Typical workflow

```powershell
# First time only — index all your media (takes a while for 42k+ files)
.\cold-backup.ps1 scan

# Check how much needs backing up
.\cold-backup.ps1 status

# Insert drives, start copying
.\cold-backup.ps1 backup

# When a drive fills up, the script stops and tells you
# Eject it, insert the next drive, run backup again
.\cold-backup.ps1 backup
```

## Preparing a blank drive

Retired drives may need formatting before use. Run this **before** inserting the drive into the backup workflow:

```powershell
.\cold-backup.ps1 init-drive G:
```

The script will show you the current drive contents, propose the next sequential label (`OFFLINE_09`, `OFFLINE_10`, etc.), and require you to type the label to confirm. It formats as NTFS.

> **Warning:** `init-drive` erases all data on the target drive. Double-check the drive letter before confirming.

## Status output

```
=== Cold Backup Status ===
Type      Files      Total  Backed %      Backed
------------------------------------------------------
Movie      2817     8.4G       43%        3.6G
Music     19854     1.2G       71%        0.9G
TV        19578    14.7G       12%        1.8G
------------------------------------------------------
Remaining : 33486 files  18.0 GB

=== Drives in Index ===
  OFFLINE_07    last on G:  1842 files  first: 2026-07-01 14:22:00
  OFFLINE_08    last on Q:  2109 files  first: 2026-07-03 09:15:00
```

## Searching

```powershell
.\cold-backup.ps1 search "Breaking Bad"
```

```
Search: 'Breaking Bad'  (47 matches)

  [OK] Breaking.Bad.S01E01.mkv  [TV]  4823.1 MB
       Drive: OFFLINE_07  →  G:\TV\Breaking Bad\Season 1\Breaking.Bad.S01E01.mkv

  [--] Breaking.Bad.S05E16.mkv  [TV]  5102.3 MB  NOT BACKED UP
       Source: T:\Kevflix_8TB_Internal_01\TV\Breaking Bad\Season 5\Breaking.Bad.S05E16.mkv
```

## Configuration

Edit the top of `cold-backup.ps1` to match your environment:

```powershell
$script:DbPath      = "$env:USERPROFILE\cold-backup\backup-index.db"
$script:DrivePrefix = 'OFFLINE_'
$script:BufferBytes = 10GB   # Free space to keep on each drive

$script:Libraries = @(
    [PSCustomObject]@{ Path = 'T:\Kevflix_8TB_Internal_01\TV'; Type = 'TV'; Label = 'tv1_T' }
    # ... add or remove libraries here
)
```

## Source libraries

Mapped from Jellyfin docker-compose volume paths to Windows drive letters:

| Label | Source Path | Type |
|---|---|---|
| tv1_T | T:\Kevflix_8TB_Internal_01\TV | TV |
| tv2_H | H:\8TB_2_Media\TV | TV |
| tv3_F | F:\KevFlix\TV Shows | TV |
| tv4_E | E:\Media Overspill\TV Shows | TV |
| movies1_T | T:\Kevflix_8TB_Internal_01\Movies | Movie |
| movies2_H | H:\8TB_2_Media\Movies | Movie |
| movies3_F | F:\KevFlix\Movies | Movie |
| movies4_E | E:\Media Overspill\Movies | Movie |
| music1_T | T:\Kevflix_8TB_Internal_01\Music | Music |
| music2_H | H:\8TB_2_Media\MP3 | Music |

## Backup drive layout

Files are copied preserving folder structure under a type subfolder:

```
OFFLINE_07:\
  TV\
    Breaking Bad\
      Season 1\
        Breaking.Bad.S01E01.mkv
  Movie\
    The Matrix (1999)\
      The.Matrix.1999.mkv
  Music\
    Pink Floyd\
      The Wall\
        01 - In the Flesh.flac
```
