#!/bin/bash
# eggd_treehouse_pipeline

# prefixes all lines of commands written to stdout with datetime
PS4='\000[$(date)]\011'
export TZ=Europe/London

# Exit at any point if there is any error and output each line as it is executed (for debugging)
# -e = exit on error; -x = output each line that is executed to log; -o pipefail = throw an error if there's an error in pipeline
set -e -x -o pipefail


_downgrade_docker(){
    : '''
    Downgrade Client and Server Docker to allow pulling docker images built in the old format
    '''
    source /home/dnanexus/resource/utils/docker_downgrade_19_03.sh
}

_download_inputs() {
    : '''
    Downloads input files, unpacks, set environment variables, and other setup steps
    '''
    mkdir -p /home/dnanexus/references_files \
        /home/dnanexus/fastqs \
        /treehouse_pipeline_github_url

    dx-download-all-inputs --parallel
    

    # Move all the fastqs from subdirectories into one directory
    find ~/in/fastqs -type f -name "*" -print0 | xargs -0 -I {} mv {} ~/fastqs

    # Move all the reference from subdirectories into one directory
    find ~/in/references_files -type f -name "*" -print0 | xargs -0 -I {} mv {} ~/references_files

    #Move the Treehouse Pipeline GitHUb url into specific folder:
    mv ~in/treehouse_pipeline_github_url - type f -name "*" -print0 | xargs -0 -I {} mv {} ~/treehouse_pipeline_github_url
}

_install_treehouse_pipeline() {
    : '''
    Clone Treehouse pipeline repository
    '''
    url_github=$(echo ~/treehouse_pipeline_github_url/*.git)
    git clone $url_github
}

_trim_fastq_endings () {
  : ''' Takes array of fastq files with their read number ("R1" or "R2"), 
  trims the endings off every file, and returns as an array
  local fastq_array=("$@")
  Define strings to remove from file name in test arrays
  This app can take fastqs with .fastq.gz suffixes so need to
  identify which suffix the input files have
  '''
  local read_to_cut=$1
  if [[ "${fastq_array[1]}" == *".fastq.gz" ]]; then
    fastq_suffix=".fastq.gz"
    export fastq_suffix
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

_fastq_checks() {
    : '''
    Checks on the fastq files
    '''
    # Tests on the reads:
    R1=($(ls *_R1_*))
    R2=($(ls *_R2_*))
    ### Tests
    ## Check that there are the same number of files in each list
    # There should be an equal number of R1 and R2 files
    if [[ ${#R1[@]} -ne ${#R2[@]} ]]; then
        echo "The number of R1 and R2 files for this sample are not equal"
        exit 1
    fi
    
    R1_test=$(_trim_fastq_endings "_R1_" ${R1[@]})
    R2_test=$(_trim_fastq_endings "_R2_" ${R2[@]})

    # Test that when "R1" and "R2" are removed the two arrays have identical file names
    for i in "${!R1_test[@]}"; do
        if [[ ! "${R2_test}" =~ "${R1_test[$i]}" ]]; then
        echo "Each R1 FASTQ does not appear to have a matching R2 FASTQ"
        exit 1
    fi

    export R1 \
        R2 \
done
}


_setup(){
    : '''
    Set up steps
    '''
    #Move fastq.gz:
    rm ~/pipelines/samples/TEST*
    mv ~/fastqs/*fast.gz ~/pipelines/samples/

    #Concate fastq.gz:
    sample_name=$(echo $R1[0] | cut -d '_' -f 1)
    cat ${sample_name}_S2_L00*_R1_001.fastq.gz > ${sample_name}_merged_R1.fastq.gz
    cat ${sample_name}_S2_L00*_R2_001.fastq.gz > ${sample_name}_merged_R2.fastq.gz
    mv ${sample_name}_S2_L00*_R*_001.fastq.gz /home/dnanexus/ # to leave only the merged fastq.gz in the correct folder
    cd ..
    export sample_name

    #Move reference files:
    mkdir -p ~/pipelines/references
    mv ~/references/* ~/pipelines/references/

    #Create outdirs:
    mkdir -p /home/dnanexus/out/output_qc_files \
        /home/dnanexus/out/output_sorted_bam \
        /home/dnanexus/out/output_expression_files
}


_upload_outputs() {
    : '''
    Upload and save outputs
    '''
    mv ~/pipelines/outputs/qc/* /home/dnanexus/out/output_qc_files/
    mv ~/pipelines/outputs/expression/*.sorted.bam /home/dnanexus/out/output_sorted_bam/
    tar -zxvf ~/pipelines/outputs/expression/TEST_R1merged.tar.gz -C /home/dnanexus/out/output_expression_files
    dx-upload-all-outputs
}

main() {
    _downgrade_docker
    _download_inputs
    _install_treehouse_pipeline
    _fastq_checks
    cd ~/pipelines
    make expression qc #Call the makefile of the Treehouse Pipeline on the functionality "expression" and "qc"
    cd ..
    _upload_outputs
}