# eggd_treehouse_pipeline

## What does this app do?

Runs the [UCSC Treehouse](https://treehouse.soe.ucsc.edu/) RNA-seq expression and QC pipelines on DNAnexus. Specifically it executes:

```bash
make expression qc
```

from the [UCSC-Treehouse/pipelines](https://github.com/UCSC-Treehouse/pipelines) repository, producing gene/isoform expression quantification (via STAR + RSEM + Kallisto) and QC metrics (via bam-umend-qc).

---

## What inputs are required for this app to run?

| Input | Class | Description |
|---|---|---|
| `fastq_R1` | array:file | One or more gzipped FASTQ files for read 1 (e.g. one per sequencing lane). Multiple files are concatenated in the order supplied before being passed to the pipeline. |
| `fastq_R2` | array:file | One or more gzipped FASTQ files for read 2 (e.g. one per sequencing lane). Multiple files are concatenated in the order supplied before being passed to the pipeline. |
| `references_files` | array:file | The three reference files required by the Treehouse pipeline (see below). A project-level suggestion path is provided in the app so these can be selected from a shared reference folder. |
| `github_repo` | file | Tar.gz file of the GitHub repository to use the Treehouse pipeline. |
| `docker_packages` | array:file | Docker packages to install docker version 19.03.x. |
| `docker_images` | array:file | Docker images for required genomic tools (see [here](https://github.com/BD2KGenomics/toil-rnaseq/blob/master/docker/README.md#genomic-tool-containers) and [here](https://github.com/UCSC-Treehouse/pipelines/blob/master/CGL_TOIL_RNA-Seq_Pipeline_versions.md)). |

### Multi-lane FASTQ handling

When a sample is split across multiple sequencing lanes, supply all R1 files as the `fastq_R1` array and all R2 files as the `fastq_R2` array. The app will download each file and concatenate them into a single merged FASTQ per read before running the pipeline:

```
samples/SAMPLE_R1_merged.fastq.gz   <- lane 1 R1 + lane 2 R1 + ...
samples/SAMPLE_R2_merged.fastq.gz   <- lane 1 R2 + lane 2 R2 + ...
```

Concatenation of `.gz` files with `cat` is valid - the gzip format supports multi-stream files and all downstream tools (STAR, RSEM, Kallisto) handle them correctly. The sample name is inferred automatically from the first R1 filename by stripping lane (`_L001`) and read (`_R1`, `_1`) suffixes.

### Reference files

The `references_files` array must contain exactly these three files, uploaded to DNAnexus with these **exact filenames**:

```
starIndex_hg38_no_alt.tar.gz
rsem_ref_hg38_no_alt.tar.gz
kallisto_hg38.idx
```

The app validates that all three are present after download and will exit with a clear error message if any are missing. Reference files can be downloaded from the UCSC Treehouse reference server and uploaded once to a shared folder in your DNAnexus project:

```
http://hgdownload.soe.ucsc.edu/treehouse/reference/starIndex_hg38_no_alt.tar.gz
http://hgdownload.soe.ucsc.edu/treehouse/reference/rsem_ref_hg38_no_alt.tar.gz
http://hgdownload.soe.ucsc.edu/treehouse/reference/kallisto_hg38.idx
```

Update the `project` and `path` values in the `references_files` suggestion block in `dxapp.json` to point to that shared folder so they are pre-selected in the DNAnexus UI.

---

## How does this app work?

1. **Docker downgrade** – `docker_downgrade_19_03.sh` (bundled under `resources/home/dnanexus/`, deployed automatically to `~/` on the worker) is executed with `sudo`. This replaces the default DNAnexus worker Docker with version 19.03, which is required for the legacy Treehouse pipeline images. See [GitHub issue](https://github.com/UCSC-Treehouse/pipelines/issues/42).

2. **Repository clone** – The Treehouse GitHub pipelines repo is extracted from the tarball github_repo input parameter.

3. **Load and replace docker images** – All the docker images are upaloaded and re-tag to the correct name so that Docker finds them.

4. **FASTQ staging and lane merging** – All R1 files are downloaded into a staging directory and concatenated into `samples/SAMPLE_R1_merged.fastq.gz`; the same is done for all R2 files. If only one file per read is supplied, the merge step is a simple copy. The merged filenames contain `_R1_` and `_R2_` so the Treehouse Makefile's regex detection picks them up correctly.

5. **Reference staging** – All files in the `reference_files` array are downloaded into `pipelines/references/` preserving their original filenames. The app then validates that the three expected filenames are present before proceeding, exiting with a clear error if any are missing.

6. **`make expression`** – Runs `quay.io/ucsc_cgl/rnaseq-cgl-pipeline` (v3.3.4-1.12.3) via Docker, using the staged STAR, RSEM, and Kallisto references. Outputs land in `outputs/expression/`.

7. **`make qc`** – Runs `ucsctreehouse/bam-umend-qc` (v1.1.1) on the sorted BAM produced by the expression step. Outputs land in `outputs/qc/`.

8. **Output upload** – All files under `outputs/expression/` and `outputs/qc/` are uploaded to DNAnexus and returned as the job's output arrays.

---

## What does this app output?

| Output | Class | Description |
|---|---|---|
| `expression_output` | array:file | All files from `outputs/expression/`, including the results tar.gz, sorted BAM, and pipeline logs. |
| `qc_output` | array:file | All files from `outputs/qc/`, including `bam_umend_qc.json`, `bam_umend_qc.tsv`, and `readDist.txt`. |

### Expression tar.gz contents

```
SAMPLE/RSEM/rsem_genes.results
SAMPLE/RSEM/rsem_isoforms.results
SAMPLE/RSEM/Hugo/rsem_genes.hugo.results
SAMPLE/RSEM/Hugo/rsem_isoforms.hugo.results
SAMPLE/Kallisto/run_info.json
SAMPLE/Kallisto/abundance.tsv
SAMPLE/Kallisto/abundance.h5
SAMPLE/QC/fastQC/R1_fastqc.html
SAMPLE/QC/fastQC/R2_fastqc.html
SAMPLE/QC/STAR/Log.final.out
SAMPLE/QC/STAR/SJ.out.tab
```

---

## Resource requirements

| Resource | Minimum |
|---|---|
| Cores | 16+ |
| Memory | 50 GB+ |
| Storage | 200 GB+ (100 GB+ references + 100 GB+ per sample) |

The app defaults to `mem2_ssd1_v2_x16` in `aws:eu-central-1`.

Expected runtime: ~8–10 hours for expression + ~1–2 hours for QC on a typical RNA-seq sample.

---

## Pipeline versions used

| Tool | Version / Image digest |
|---|---|
| treehouse-pipeline | https://github.com/UCSC-Treehouse/pipelines
| rnaseq-cgl-pipeline | `3.3.4-1.12.3` – `sha256:785eee9f750ab91078d84d1ee779b6f74717eafc09e49da817af6b87619b0756` |
| bam-umend-qc | `1.1.1` – `sha256:5f286d72395fcc5085a96d463ae3511554acfa4951aef7d691bba2181596c31f` |
| cutadapt | `1.9` - `6bd44edd2b8f8f17e25c5a268fedaab65fa851d2` |
| star | `2.4.2a` - `bcbd5122b69ff6ac4ef61958e47bde94001cfe80` |
| rsem | `1.2.25` - `d4275175cc8df36967db460b06337a14f40d2f21` |
| gencode_hugo_mapping | `1.0` - `cb4865d02f9199462e66410f515c4dabbd061e4d` |
| samtools | `1.3` - `256539928ea162949d8a65ca5c79a72ef557ce7c` |
| fastqc | `0.11.5` - `be13567d00cd4c586edf8ae47d991815c8c72a49` |
| kallisto | `0.43.1` - `355c19b1fb6fbb85f7f8293e95fb8a1e9d0da163` |
| rsem | `rsem_postprocess` |

---

## This app was made by East GLH
Disclaimer: [Claude AI](https://platform.claude.com/) was used to assemble the code.