#!/bin/bash
# eggd_treehouse_pipeline

# prefixes all lines of commands written to stdout with datetime
PS4='\000[$(date)]\011'
export TZ=Europe/London

# Exit at any point if there is any error and output each line as it is executed (for debugging)
# -e = exit on error; -x = output each line that is executed to log; -o pipefail = throw an error if there's an error in pipeline
set -e -x -o pipefail


_trim_fastq_endings () {
  # Takes array of fastq files with their read number ("R1" or "R2"), 
  # trims the endings off every file, and returns as an array.
  # Usage: _trim_fastq_endings <string_to_cut> <file_name>
    #
    # Arguments:
    # string_to_cut : the pattern 'R1' or 'R2' to be removed from the name
    # file_name : the fastqs file name to be removed R1/R2 and suffix from 

  local fastq_array=("$@")
  local read_to_cut=$1
  if [[ "${fastq_array[1]}" == *".fastq.gz" ]]; then
    fastq_suffix=".fastq.gz"
  else
    echo "Suffixes of fastq files not recognised as .fastq.gz"
    exit 1
  fi
  
  for i in "${!fastq_array[@]}"; do
    fastq_array[$i]=${fastq_array[$i]//$read_to_cut/};
    fastq_array[$i]=${fastq_array[$i]//$fastq_suffix/};
  done
  echo ${fastq_array[@]}
}

stage_fastqs() {
    # Check on fastqs files and stage them. 
    # If more than one per read, concatenates them and outputs
    # the single merged R1 and R2 file in samples/.
    #
    # The merged files are named:
    #   samples/SAMPLE_R1_merged.fastq.gz
    #   samples/SAMPLE_R2_merged.fastq.gz
    #
    # cat on .gz files is valid — gzip format supports concatenated streams
    # and all downstream tools (STAR, Kallisto, etc.) handle them correctly.
    echo ">>> Staging FASTQ input files..."
    mkdir -p /home/dnanexus/samples

    ## Checks
    ### List fastqs
    R1=($(ls /home/dnanexus/in/fastq_R1/*/*_R1*))
    R2=($(ls /home/dnanexus/in/fastq_R2/*/*_R2*))

    ### Check that there are the same number of files in each list
    ### There should be an equal number of R1 and R2 files
    if [[ ${#R1[@]} -ne ${#R2[@]} ]]
        then echo "The number of R1 and R2 files for this sample are not equal"
    exit 1
    fi

    ### Check that each R1 has a matching R2
    ### Remove "R1" and "R2" and the file suffix from all file names
    R1_test=$(_trim_fastq_endings "_R1" ${R1[@]})
    R2_test=$(_trim_fastq_endings "_R2" ${R2[@]})

    # Test that when "R1" and "R2" are removed the two arrays have identical file names
    for i in "${!R1_test[@]}"; do
        if [[ ! "${R2_test}" =~ "${R1_test[$i]}" ]];
        then echo "Each R1 FASTQ does not appear to have a matching R2 FASTQ"
        exit 1
        fi
    done

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
    cat /home/dnanexus/in/fastq_R1/*/* > "samples/${sample_name}_R1_merged.fastq.gz"

    echo ">>> Merging R2 lanes -> samples/${sample_name}_R2_merged.fastq.gz"
    cat /home/dnanexus/in/fastq_R2/*/* > "samples/${sample_name}_R2_merged.fastq.gz"
    
    echo ">>> samples/ contents:"
    ls -lh samples/
}


stage_references() {
    # Reference files are moved to references/ folder and check for their filename.
    # The Treehouse Makefile expects exactly these three files to be present:
    #   references/starIndex_hg38_no_alt.tar.gz
    #   references/rsem_ref_hg38_no_alt.tar.gz
    #   references/kallisto_hg38.idx
    # The actual check searches for inclusion of the tool name and file extension for starIndex and rsem (e.g.: *rsem*).
    # If the tool name is included, then the name is modified into the correct one.
    # Otherwise, an Exit Error is raised.

    echo ">>> Staging reference files into references/..."
    mkdir -p /home/dnanexus/references

    # Print the name of the references files as given in references_files app input
    mv /home/dnanexus/in/references_files/*/* /home/dnanexus/references/ 
    echo ">>> references/ contents:"
    ls -lh references/


    # Loop over files to find which one has a different name
    # but still contain the name of the tool to be the reference for
    for actual_file in references/*; do
        target="" #set every iteration
        base=$(basename "$actual_file")
        # find which filename is incorrect and assign the respective corrected (target) name
        case "$base" in
            *starIndex*.tar.gz)
                target="references/starIndex_hg38_no_alt.tar.gz"
                ;;
            *rsem*.tar.gz)
                target="references/rsem_ref_hg38_no_alt.tar.gz"
                ;;
            *kallisto*)
                target="references/kallisto_hg38.idx"
                ;;
            *) # if not matching then throw an error
                echo -e "ERROR: $base not including the expected filename pattern:\n\
                Please ensure the reference_files input includes:\n\
                starIndex*.tar.gz\n\
                rsem*.tar.gz\n\
                kallisto*" >&2
                exit 1
                ;;
        esac
        # Only rename/move if file name is different
        if [[ -n "$target" ]]; then #guard from target being empty
            if [[ "$actual_file" != "$target" ]]; then
                mv "$actual_file" "$target"
                echo "Renamed $base → $(basename "$target")"
            else
                echo "$base already correctly named"
            fi
        fi
    done

    # Print the name of the references files after checking them and renaming them if needed:
    echo ">>> references/ contents:"
    ls -lh references/
    echo ">>> All expected reference files are present."
}


extract_pipeline() {
    # Extract the UCSC Treehouse pipelines repository and moves into it.
    # Samples and references folder are moved in the repository folder.
    # All subsequent steps assume the working directory is pipelines/
    echo ">>> Extracting Treehouse pipelines repository..."

    mkdir /home/dnanexus/repo_extract

    tar xvzf "${github_repo_path}" -C /home/dnanexus/repo_extract

    REPO_DIR=$(find /home/dnanexus/repo_extract -mindepth 1 -maxdepth 1 -type d | head -n 1)
    
    ## Checking that repo did exists
    if [[ -z "${REPO_DIR}" ]]; then
        echo "ERROR: failed to extract repository"
        exit 1
    fi

    echo "Repository extracted to:"
    echo "${REPO_DIR}"

    rm -r ${REPO_DIR}/samples/ #remove already present TEST files in samples/ directory
    
    mv /home/dnanexus/references/ ${REPO_DIR}/
    mv /home/dnanexus/samples/ ${REPO_DIR}/
    
    cd "${REPO_DIR}" || exit 1
}

load_and_replace_docker_images(){
    # Load docker images and replace the image ID in the Makefile.
    # This function is valid only for rnaseq-cgl-pipeline and umend_qc.

    echo ">>> Running: Load docker images"

    mkdir -p docker_images
    
    ## rnaseq
    rnaseq=$(ls /home/dnanexus/in/docker_images/*/rnaseq*.tar.gz)
    docker load -i "$rnaseq"
    
    docker images
        
    OLD_rnaseq="quay.io/ucsc_cgl/rnaseq-cgl-pipeline@sha256:785eee9f750ab91078d84d1ee779b6f74717eafc09e49da817af6b87619b0756"
    NEW_rnaseq=$(docker images --format="{{.Repository}} {{.ID}}" | grep "rnaseq-cgl-pipeline" | cut -d' ' -f2)

    echo $NEW_rnaseq

    sed -i "s#$OLD_rnaseq#$NEW_rnaseq#g" Makefile

    ## umendqc
    umend_qc=$(ls /home/dnanexus/in/docker_images/*/bam_umend_qc*.tar.gz)
    docker load -i "$umend_qc"
    OLD_umend="ucsctreehouse/bam-umend-qc@sha256:5f286d72395fcc5085a96d463ae3511554acfa4951aef7d691bba2181596c31f"
    NEW_umend=$(docker images --format="{{.Repository}} {{.ID}}" | grep "bam_umend_qc" | cut -d' ' -f2)
    
    echo $NEW_umend
    
    sed -i "s#$OLD_umend#$NEW_umend#g" Makefile
    
    # Visual check that the Makefile has the new image IDs
    grep -E "$NEW_rnaseq|$NEW_umend" Makefile
}

load_and_tag() {
    # Load a docker image with manifesto v2 and re-tag it with its full original name,
    # so it is found locally when called by the rnaseq-cgl-pipeline container.
    #
    # Usage: load_and_tag <tar_path> <full_image_name>
    #
    # Arguments:
    # tar_path        : path to the .tar.gz docker image file
    # full_image_name : the full original name to tag it with
    #                     (e.g. "quay.io/ucsc_cgl/kallisto:0.42.4--35ac87df...")

    local tar_path
    local full_image_name
    tar_path="$1"
    full_image_name="$2"

    echo ">>> Loading: $tar_path"
    loaded_ref=$(docker load -i "$tar_path" | cut -d " " -f 3)
    if [[ "$loaded_ref" != "$full_image_name" ]]; then
        echo ">>> Re-tagging $loaded_ref -> $full_image_name"
        docker tag "$loaded_ref" "$full_image_name"
    fi

    echo ">>> Verifying image $full_image_name is present:"
    if ! docker images --format="{{.Repository}}:{{.Tag}}" | grep -qF "$full_image_name"; then
        echo "ERROR: Expected image '$full_image_name' not found after loading $tar_path"
        exit 1
    fi
    echo ">>> OK: $full_image_name"
}

run_load_and_tag_docker(){
    # Run the load_and_tag() for each of the tools required by rnaseq-cgl-pipeline.
    # Each docker must be tagged with its exact original name so Docker finds them locally.
    # Each original name is hard-coded in the docker of Treehouse.
    # As output, the docker image with the manifesto v2 are re-tagged to the docker
    # name present in the Treehouse code.
    
    ## Resolve glob paths first
    local cutadapt_tar kallisto_tar star_tar rsem_tar fastqc_tar

    cutadapt_tar=$(ls /home/dnanexus/in/docker_images/*/cutadapt*.tar.gz)
    kallisto_tar=$(ls /home/dnanexus/in/docker_images/*/kallisto*.tar.gz)
    star_tar=$(ls /home/dnanexus/in/docker_images/*/star*.tar.gz)
    rsem_tar=$(ls /home/dnanexus/in/docker_images/*/rsem_1*.tar.gz)
    fastqc_tar=$(ls /home/dnanexus/in/docker_images/*/fastqc*.tar.gz)
    gencode_hugo_mapping_tar=$(ls /home/dnanexus/in/docker_images/*/gencode_hugo_mapping*.tar.gz)
    samtools_tar=$(ls /home/dnanexus/in/docker_images/*/samtools*.tar.gz)
    rsem_postprocess_tar=$(ls /home/dnanexus/in/docker_images/*/rsem_postprocess*.tar.gz)

    load_and_tag "$cutadapt_tar" \
        "quay.io/ucsc_cgl/cutadapt:1.9--6bd44edd2b8f8f17e25c5a268fedaab65fa851d2"

    load_and_tag "$kallisto_tar" \
        "quay.io/ucsc_cgl/kallisto:0.43.1--355c19b1fb6fbb85f7f8293e95fb8a1e9d0da163"

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

run_pipelines() {
    # Runs the Treehouse expression pipeline followed by the QC pipeline.
    # The qc automatically picks up the sorted BAM produced by expression.
    echo ">>> Running: make expression"
    make expression

    echo ">>> Running: make qc"
    make qc
}

upload_outputs() {
    # Stage and upload expression and QC outputs to DNAnexus.
    # The expression/*.tar.gz is extracted and its files are uploaded in DNAnexus, while the *.tar.gz is then removed.
    echo ">>> Staging expression outputs..."
    mkdir -p /home/dnanexus/out/expression_output
    
    tar xvzf outputs/expression/*.tar.gz -C outputs/expression/
    rm outputs/expression/*.tar.gz
    
    mv outputs/expression/* /home/dnanexus/out/expression_output/


    echo ">>> Staging QC outputs..."
    mkdir -p /home/dnanexus/out/qc_output
    mv outputs/qc/* /home/dnanexus/out/qc_output/

    echo ">>> Uploading all outputs..."
    dx-upload-all-outputs --parallel
}

main() {
    # Run the main pipeline with the function in order

    echo "=========================================="
    echo " eggd_treehouse_pipeline v1.0.0"
    echo " UCSC Treehouse expression + QC pipelines"
    echo "=========================================="

    dx-download-all-inputs
    stage_fastqs
    stage_references
    extract_pipeline # from now on, the functions will run inside the pipeline/ folder
    load_and_replace_docker_images
    run_load_and_tag_docker
    run_pipelines
    upload_outputs

    echo ">>> eggd_treehouse_pipeline complete."
}