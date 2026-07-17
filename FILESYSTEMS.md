# Filesystems & Litestack

In the containerized world we live in, many layers of the hardware/software stacks are far abstracted that we no longer know they exist. For the filesystem enthusiasts out there this is a quick overview of how Litestack (and hence SQLite) can benefit from different filesystem

## XFS

A very stable and trusted filesystem with excellent performance characteristics

- Fast reads / writes

## EXT4

Another stable and performant filesystem

- Fast reads / writes

## F2FS

Specially built for solid state storage, has an atomic write mode that is supported by SQLite

- Fast reads
- Reasonably fast durable writes in synchronous mode
- Compression (not very useful)

## ZFS

Copy-on-write filesystem with a nifty set of features, very fast snapshotting but only for the FS as a whole, can send incremental snapshots to another host for backup. Naturally a lot more pages are written on write operations thus it is a bit slower in writes.

- Fast reads
- Slower writes
- FS Snapshotting with send/recv
- fast device cache
- Compression

## Btrfs

Another CoW filesystem that delivers snapshotting and incremental send/recv at a much granular level.

- Fast reads
- Slower writes
- Fast copies (free backups)
- Sub volume Snapshotting with send/recv
- Compression

## Bcachefs

A new CoW filesystem built on the foundations of the bcache module. Improving rapidly but still lacks a few of the common CoW fs features

- Fast reads
- Slower writes
- fast device cache





## Migration backups (1.0+)

Destructive schema upgrades create a sibling snapshot named
`.litestack-backup-v<source_version>-<UTC>-<pid>.sqlite3` next to the durable
database via SQLite online backup (separate read-source and destination
connections). Snapshots are verified with full `PRAGMA integrity_check` and
`PRAGMA foreign_key_check`, then published with same-directory hard-link
no-replace semantics. Backups are never auto-deleted. Ephemeral Litecache and
Litecable files may be rebuilt without backup.

### Recoverability promise

The durable upgrade/backup guarantee applies only to **local filesystems** with
reliable advisory locks, SQLite write locks, `fsync`, directory `fsync`, and
same-filesystem hard-link publication. Network filesystems, aliases, and
cross-volume temporary paths are rejected (`BackupPublicationError`) or are
explicitly outside the power-loss recoverability promise.
