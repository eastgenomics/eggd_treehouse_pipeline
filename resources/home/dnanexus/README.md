# resources/home/dnanexus

Files placed in this directory are automatically deployed to `~/` on the DNAnexus worker at job start, before `src/code.sh` runs.

## Required file

| File | Purpose |
|---|---|
| `docker_downgrade_19_03.sh` | Downgrades Docker to v19.03 on the worker so that legacy Treehouse Docker images (`quay.io/ucsc_cgl/rnaseq-cgl-pipeline`, `ucsctreehouse/bam-umend-qc`) can be loaded and run. |

**Add `docker_downgrade_19_03.sh` to this directory before building the app.**  
It is called in `src/code.sh` as:

```bash
sudo bash ~/docker_downgrade_19_03.sh
```
