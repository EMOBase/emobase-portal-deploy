# BLAST

`blast/links_jbrowse2.rb` is loaded as a SequenceServer extension and adds a
**Genome Browser** link to hits from a `*-genome` nucleotide database. The link
opens JBrowse2 at the hit coordinates with a temporary BLAST-hit track.

The assembly is derived from the BLAST database name (`v2a4-genome` → `v2a4`),
which is also the JBrowse2 assembly name. Hits from protein or RNA databases
get no link, since JBrowse2 uses the genome assembly as the reference. The link
is only added when a single genome database is selected; mixed searches omit it
so the results page does not run a `blastdbcmd` lookup per hit.

The extension reads assembly track IDs from the shared JBrowse2 config, so the
`blast` service mounts `jbrowse2-data` read-only at `/jbrowse2`.

The link is absolute to `PUBLIC_SERVER`, so it works regardless of which
origin embeds the BLAST page.

## Databases and restarts

BLAST databases are created by the genomics workers (`SETUP_BLAST` jobs) from
a release and written to the `blast-data` volume. Check
`/blast/searchdata.json` to see what the running SequenceServer has picked up.

`/var/run/docker.sock` is mounted into the workers because they restart the
`blast` container after rebuilding databases. The container name is controlled
by `BLAST_CONTAINER_NAME` and must match the `blast` service.

For local builds and the Apple Silicon/Rosetta requirement, see
[DEVELOPMENT.md](DEVELOPMENT.md). For the deployment order, see the
[deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md).
