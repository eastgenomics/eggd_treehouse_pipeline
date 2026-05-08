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
    local version
    version=$(docker --version| grep -o "19.03")
    
    if [[ "${version}" != "19.03" ]]; then
        echo "ERROR: Docker version is not 19.03"
        exit 1
    fi
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

load_and_replace_docker_images(){
    # Load docker images and replace the name in the Makefile for rnaseq-cgl-pipeline and umend_qc available
    echo ">>> Running: Load docker images"

    mkdir -p docker_images
    docker load -i /home/dnanexus/in/docker_images/0/*.tar.gz
    

    docker images
    
    #Replace the docker image in the Makefile
    ##rnaseq
    OLD_rnaseq="quay.io/ucsc_cgl/rnaseq-cgl-pipeline@sha256:785eee9f750ab91078d84d1ee779b6f74717eafc09e49da817af6b87619b0756"
    NEW_rnaseq=$(docker images --format="{{.ID}}")

    echo $NEW_rnaseq

    sed -i "s#$OLD_rnaseq#$NEW_rnaseq#g" Makefile

    ##umendqc
    docker load -i /home/dnanexus/in/docker_images/1/*.tar.gz
    OLD_umend="ucsctreehouse/bam-umend-qc@sha256:5f286d72395fcc5085a96d463ae3511554acfa4951aef7d691bba2181596c31f"
    NEW_umend=$(docker images --format="{{.ID}}" | grep -w -v "$NEW_rnaseq")
    
    echo $NEW_umend
    
    sed -i "s#$OLD_umend#$NEW_umend#g" Makefile

    grep -E "$NEW_rnaseq|$NEW_umend" Makefile
}

load_and_tag() {
    # Load a docker image and re-tag it with its full original name,
    # so it is found locally when called by the rnaseq-cgl-pipeline container.
    #
    # Usage: load_and_tag <tar_path> <full_image_name>
    #
    # Arguments:
    #   tar_path        : path to the .tar.gz docker image file
    #   full_image_name : the full original name to tag it with
    #                     (e.g. "quay.io/ucsc_cgl/kallisto:0.42.4--35ac87df...")

        local tar_path
    local full_image_name
    tar_path="$1"
    full_image_name="$2"

    echo ">>> Loading: $tar_path"
    docker load -i "$tar_path"

    echo ">>> Verifying image $full_image_name is present:"
    if ! docker images --format="{{.Repository}}:{{.Tag}}" | grep -qF "$full_image_name"; then
        echo "ERROR: Expected image '$full_image_name' not found after loading $tar_path"
        exit 1
    fi
    echo ">>> OK: $full_image_name"
}

run_load_and_tag_docker(){
    # These are called internally by rnaseq-cgl-pipeline at runtime —
    # must be tagged with their exact original name so Docker finds them locally
    # Resolve glob paths first
    local rnaseq_tar umend_tar cutadapt_tar kallisto_tar star_tar rsem_tar fastqc_tar

    cutadapt_tar=$(ls /home/dnanexus/in/docker_images/*/cutadapt*.tar.gz)
    kallisto_tar=$(ls /home/dnanexus/in/docker_images/*/kallisto*.tar.gz)
    star_tar=$(ls /home/dnanexus/in/docker_images/*/star*.tar.gz)
    rsem_tar=$(ls /home/dnanexus/in/docker_images/*/rsem*.tar.gz)
    fastqc_tar=$(ls /home/dnanexus/in/docker_images/*/fastqc*.tar.gz)
    gencode_hugo_mapping_tar=$(ls /home/dnanexus/in/docker_images/*/gencode_hugo_mapping*.tar.gz)
    samtools_tar=$(ls /home/dnanexus/in/docker_images/*/samtools*.tar.gz)
    rsem_postprocess_tar=$(ls /home/dnanexus/in/docker_images/*/rsem_postprocess*.tar.gz)

    load_and_tag "$cutadapt_tar" \
        "quay.io/ucsc_cgl/cutadapt:1.9--6bd44edd2b8f8f17e25c5a268fedaab65fa851d2"

    load_and_tag "$kallisto_tar" \
        "quay.io/ucsc_cgl/kallisto:0.42.4--35ac87df5b21a8e8e8d159f26864ac1e1db8cf86"

    load_and_tag "$star_tar" \
        "quay.io/ucsc_cgl/star:2.4.2a--bcbd5122b69ff6ac4ef61958e47bde94001cfe80"

    load_and_tag "$rsem_tar" \
        "quay.io/ucsc_cgl/rsem:1.2.25--d4275175cc8df36967db460b06337a14f40d2f21"

    load_and_tag "$fastqc_tar" \
        "quay.io/ucsc_cgl/fastqc:0.11.5--be13567d00cd4c586edf8ae47d991815c8c72a49"

    load_and_tag "$gencode_hugo_mapping_tar" \
        "quay.io/ucsc_cgl/gencode_hugo_mapping:1.0--cb4865d02f9199462e66410f515c4dabbd061e4d"
    
    load_and_tag "$samtools_tar" \
        "quay.io/ucsc_cgl/samtools:1.3--256539928ea162949d8a65ca5c79a72ef557ce7c"
    
    load_and_tag "$rsem_postprocess_tar" \
        "jvivian/rsem_postprocess"   
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
    mkdir -p samples

    # Derive a sample name from the first R1 filename, stripping lane/read
    # suffixes to produce a clean prefix (e.g. SAMPLE_L001_R1.fastq.gz -> SAMPLE)
    local first_r1_name
    first_r1_name=$(dx describe "${fastq_R1[0]}" --name)
    local sample_name
    sample_name=$(echo "${first_r1_name}" | cut -d '_' -f 1)

    echo ">>> Inferred sample name: ${sample_name}"

    # Merge lanes by concatenation into samples/
    # cat is safe for .gz: gzip supports multi-stream files
    echo ">>> Merging R1 lanes -> samples/${sample_name}_R1_merged.fastq.gz"
    cat /home/dnanexus/in/fastq_R1/* > "samples/${sample_name}_R1_merged.fastq.gz"

    echo ">>> Merging R2 lanes -> samples/${sample_name}_R2_merged.fastq.gz"
    cat /home/dnanexus/in/fastq_R2/* > "samples/${sample_name}_R2_merged.fastq.gz"
    
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

    mv /home/dnanexus/in/references_files/*/* references/

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
    load_and_replace_docker_images
    run_load_and_tag_docker
    stage_fastqs
    stage_references
    run_pipelines
    upload_outputs

    echo ">>> eggd_treehouse_pipeline complete."
}