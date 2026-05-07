#!/bin/bash
# eggd_treehouse_pipeline

# prefixes all lines of commands written to stdout with datetime
PS4='\000[$(date)]\011'
export TZ=Europe/London

# Exit at any point if there is any error and output each line as it is executed (for debugging)
# -e = exit on error; -x = output each line that is executed to log; -o pipefail = throw an error if there's an error in pipeline
set -e -x -o pipefail

downgrade_docker() {
    # Downgrades Docker to v19.03 using the script bundled under
    # resources/home/dnanexus/, which DNAnexus deploys automatically to ~/
    echo ">>> Downgrading Docker to version 19.03..."
    sudo bash ~/docker_downgrade_19_03.sh
    echo ">>> Docker version after downgrade: $(docker --version)"
}

extract_pipeline() {
    # Clones the UCSC Treehouse pipelines repository and moves into it.
    # All subsequent steps assume the working directory is pipelines/
    echo ">>> Extracting Treehouse pipelines repository..."

    mkdir /home/dnanexus/repo_extract

    tar xvzf /home/dnanexus/in/github_repo/pipelines.tar.gz -C /home/dnanexus/repo_extract

    REPO_DIR=$(find /home/dnanexus/repo_extract -mindepth 1 -maxdepth 1 -type d | head -n 1)

    if [[ -z "${REPO_DIR}" ]]; then
        echo "ERROR: failed to extract repository"
        exit 1
    fi

    echo "Repository extracted to:"
    echo "${REPO_DIR}"

    cd "${REPO_DIR}" || exit 1
}


stage_fastqs() {
    # Downloads all R1 and R2 FASTQ files (one or more per read, e.g. one
    # per sequencing lane) into a staging directory, then concatenates them
    # into a single merged R1 and R2 file in samples/.
    #
    # The merged files are named:
    #   samples/SAMPLE_R1_merged.fastq.gz
    #   samples/SAMPLE_R2_merged.fastq.gz
    #
    # cat on .gz files is valid — gzip format supports concatenated streams
    # and all downstream tools (STAR, Kallisto, etc.) handle them correctly.
    echo ">>> Staging FASTQ input files..."
    mkdir -p fastq_staging samples

    # Derive a sample name from the first R1 filename, stripping lane/read
    # suffixes to produce a clean prefix (e.g. SAMPLE_L001_R1.fastq.gz -> SAMPLE)
    local first_r1_name
    first_r1_name=$(dx describe "${fastq_R1[0]}" --name)
    local sample_name
    sample_name=$(echo "${first_r1_name}" | cut -d '_' -f 1)

    echo ">>> Inferred sample name: ${sample_name}"

    # Download all R1 files
    echo ">>> Downloading R1 file(s)..."
    local r1_files=()
    for r1 in "${fastq_R1[@]}"; do
        local r1_name
        r1_name=$(dx describe "${r1}" --name)
        echo "    ${r1_name}"
        dx download "${r1}" -o "fastq_staging/${r1_name}"
        r1_files+=("fastq_staging/${r1_name}")
    done

    # Download all R2 files
    echo ">>> Downloading R2 file(s)..."
    local r2_files=()
    for r2 in "${fastq_R2[@]}"; do
        local r2_name
        r2_name=$(dx describe "${r2}" --name)
        echo "    ${r2_name}"
        dx download "${r2}" -o "fastq_staging/${r2_name}"
        r2_files+=("fastq_staging/${r2_name}")
    done

    # Merge lanes by concatenation into samples/
    # cat is safe for .gz: gzip supports multi-stream files
    echo ">>> Merging R1 lanes -> samples/${sample_name}_R1_merged.fastq.gz"
    cat "${r1_files[@]}" > "samples/${sample_name}_R1_merged.fastq.gz"

    echo ">>> Merging R2 lanes -> samples/${sample_name}_R2_merged.fastq.gz"
    cat "${r2_files[@]}" > "samples/${sample_name}_R2_merged.fastq.gz"
    
    rm samples/TEST.bam samples/TEST_R1.fastq.gz samples/TEST_R2.fastq.gz #remove already present files
    echo ">>> samples/ contents:"
    ls -lh samples/
}


stage_references() {
    # Downloads all files from the reference_files array into references/,
    # preserving their original filenames. The Treehouse Makefile expects
    # exactly these three files to be present:
    #   references/starIndex_hg38_no_alt.tar.gz
    #   references/rsem_ref_hg38_no_alt.tar.gz
    #   references/kallisto_hg38.idx
    echo ">>> Staging reference files into references/..."
    mkdir -p references

    for ref in "${references_files[@]}"; do
        local ref_name
        ref_name=$(dx describe "${ref}" --name)
        echo "    Downloading: ${ref_name}"
        dx download "${ref}" -o "references/${ref_name}"
    done

    echo ">>> references/ contents:"
    ls -lh references/

    # Validate that the expected filenames are present
    local expected=("starIndex_hg38_no_alt.tar.gz" "rsem_ref_hg38_no_alt.tar.gz" "kallisto_hg38.idx")
    for f in "${expected[@]}"; do
        if [[ ! -f "references/${f}" ]]; then
            echo "ERROR: Expected reference file not found: references/${f}"
            echo "       Please ensure the reference_files input contains files with these exact names:"
            echo "         starIndex_hg38_no_alt.tar.gz"
            echo "         rsem_ref_hg38_no_alt.tar.gz"
            echo "         kallisto_hg38.idx"
            exit 1
        fi
    done

    echo ">>> All expected reference files present."
}


run_pipelines() {
    # Runs the Treehouse expression pipeline followed by the QC pipeline.
    # The qc target automatically picks up the sorted BAM produced by expression.
    echo ">>> Running: make expression"
    make expression

    echo ">>> Running: make qc"
    make qc
}


upload_outputs() {
    # Uploads all files from outputs/expression/ and outputs/qc/ back to
    # DNAnexus and sets the job output arrays.
    echo ">>> Uploading expression outputs..."
    expression_output=()
    while IFS= read -r -d '' f; do
        echo "    Uploading: ${f}"
        file_id=$(dx upload "${f}" --brief)
        expression_output+=("${file_id}")
    done < <(find outputs/expression -type f -print0)

    echo ">>> Uploading QC outputs..."
    qc_output=()
    while IFS= read -r -d '' f; do
        echo "    Uploading: ${f}"
        file_id=$(dx upload "${f}" --brief)
        qc_output+=("${file_id}")
    done < <(find outputs/qc -type f -print0)

    echo ">>> Upload complete."
    echo "    Expression files uploaded: ${#expression_output[@]}"
    echo "    QC files uploaded:         ${#qc_output[@]}"

    dx-jobutil-add-output expression_output --array --class=file "${expression_output[@]}"
    dx-jobutil-add-output qc_output --array --class=file "${qc_output[@]}"
}


main() {

    echo "=========================================="
    echo " eggd_treehouse_pipeline v1.0.0"
    echo " UCSC Treehouse expression + QC pipelines"
    echo "=========================================="

    dx-download-all-inputs # download inputs from json
    downgrade_docker
    extract_pipeline
    stage_fastqs
    stage_references
    run_pipelines
    upload_outputs

    echo ">>> eggd_treehouse_pipeline complete."
}