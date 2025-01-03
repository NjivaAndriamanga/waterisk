/*

*/
process TEST_PROCESS {
    label 'process_high'

    output:
    stdout

    script:
    """
    echo "${task.cpus} ${task.memory}"
    """
}

/*
This process will download the plasme database from github and unzip it in the same directory as the main script (main.nf)
Run PLasme.py script to unzip and install the dabatase (avoid conflict when accessing the database during plasme process)
Alternative: download the database from plasme and unzip it waterisk directory with the name DB

Database for kraken and for virulence factor detection
But if the directory DB already exist, it will not be re-downloaded

*/
process DOWNLOAD_PLASME_DATABASE {
    label 'plasme'

    output:
    env output

    script:

    if (params.plasme_download_db == true) {
        log.info "Downloading plasme database..."
        """
        cd ${projectDir}
        if [ ! -d DB ]; then 
            echo "Download plasme db in tar format"
            tar -xvf DB.tar.gz
            output="PLASME DB OK"
        else
            output=" Plamse DB already exist"
        fi
        """
    }
    else if (params.plasme_download_db == false) {
        """
        output="DB are already provided"
        """
    }
}

process DOWNLOAD_KRAKEN_DATABASE {
   output:
   env output

   script:
   if (params.kraken_db.equals("${projectDir}/k2_standard_08gb_20240904") && params.kraken_taxonomy == true) {
        log.info "Downloading kraken database..."
        """
        cd ${projectDir}
        if [ ! -d k2_standard_08gb_20240904 ]; then
            mkdir k2_standard_08gb_20240904
            wget https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08gb_20240904.tar.gz
            tar -xvf k2_standard_08gb_20240904.tar.gz -C k2_standard_08gb_20240904/
            output="Kraken DB OK"
        else
            output=" Kraken DB already exist "
        fi
        """
    }
    else if (params.kraken_taxonomy == true && params.kraken_db != "${projectDir}/k2_standard_08gb_20240904" && params.kraken_db != null) {
        """
        output="Kraken DB are already provided"
        """
    }
}

process DOWNLOAD_VF_DATABASE {
    output:
    env output

    script:
    log.info "Downloading VF database..."
    """
    cd ${projectDir}
    if [ ! -d VF_db ]; then
        mkdir VF_db
        wget https://www.mgc.ac.cn/VFs/Down/VFDB_setB_nt.fas.gz
        gzip -d VFDB_setB_nt.fas.gz
        mv VFDB_setB_nt.fas VF_db/
        cd VF_db
        makeblastdb -in VFDB_setB_nt.fas -dbtype nucl
        output="VF DB OK"
    else
        output="VF DB already exist"
    fi
    """
}

process DOWNLOAD_DBSCAN {
    output:
    env output

    script:
    log.info "Downloading DBSCAN database..."
    """
    
    cd ${projectDir}
    if [ ! -d DBSCAN-SWA ]; then
        git clone https://github.com/HIT-ImmunologyLab/DBSCAN-SWA
        chmod u+x -R DBSCAN-SWA/bin
        chmod u+x -R DBSCAN-SWA/software
        export PATH=$PATH:${projectDir}/DBSCAN-SWA/software/blast+/bin
        export PATH=$PATH:${projectDir}/DBSCAN-SWA/bin
        export PATH=$PATH:${projectDir}/DBSCAN-SWA/software/diamond
        output="Downloading DBSCAN from github OK. "
    else
        output="DBSCAN tools OK."
    fi

    cd ${projectDir}/DBSCAN-SWA
    if [ ! -d db ]; then
        wget https://zenodo.org/records/10404224/files/db.tar.gz
        tar -xvf db.tar.gz
        output+="db for DBSCAN OK. "
    else
        output+="db for DBSCAN already exist. "
    fi
    
    """
}

process DBSCAN {
    publishDir "${params.output_dir}dbscan/"

    input:
    tuple val(barID) ,path(chromosome_fasta)
    val x

    output:
    tuple val(barID) ,path("${barID}_DBSCAN.txt")

    script:
    """
    python ${projectDir}/DBSCAN-SWA/bin/dbscan-swa.py --thread_num ${task.cpus} --input ${chromosome_fasta} --output dbscan_output
    mv dbscan_output/bac_DBSCAN-SWA_prophage_summary.txt ${barID}_DBSCAN.txt
    """
}


/*
List all barcodes contain in the input directory from miniON output
*/
process IDENTIFIED_RAW_SAMPLES {
    input:
    path fastq_dir
    val fastq_path

    output:
    path '*.txt'

    script:
    """
    ls ${fastq_dir}/ > path_list.txt
    while read -r line; do basename=\$(echo \$line | awk '{n=split(\$0,A,"/"); print A[n]}'); output_file="\${basename}.txt"; echo "${fastq_path}\$line" > \$output_file; done < path_list.txt
    rm path_list.txt
    """
}

/*
    Identified samples from index_files and check the presence of short reads
*/
process IDENTIFIED_SAMPLES {
    input:
    tuple path(fastq), val(genome_size), path(sr1), path(sr2)

    output:
    tuple val(barID), path(fastq), emit: long_reads
    tuple val(barID), val(genome_size), emit: genome_size
    tuple val(barID), path(sr1), path(sr2), emit: short_reads
    
    script:
    barID = fastq.getSimpleName()

    """
    
    """
}

/*
Merge all seprates fastq.gz for each barcodes file into one file
*/
process MERGE_SEPARATE_FASTQ {
    input:
    path barcode_dir

    output:
    tuple val(barID), path("${barID}.fastq.gz")

    script:
    barID = barcode_dir.getSimpleName()
    """
        while read -r line; do cat \${line}/*.fastq.gz > ${barID}.fastq.gz; done < $barcode_dir
    """
}

/*
Long reads trimming by length and quality score and filtering with cutadapt. Asses reads quality before and reads filtering with fastqc. The two reports are merged with multiqc
*/
process CLEAN_LONG_READS {
    label "process_high"
    publishDir "${params.output_dir}trimmed_output/"
    
    input:
    tuple val(barID), path(query)

    output:
    tuple val(barID), path("${barID}Trimmed.fastq.gz"), emit: trimmed_fastq

    script:
    """
    cutadapt --cut ${params.trim_end_size} --cut -${params.trim_end_size} -q ${params.quality_trim},${params.quality_trim} -o ${barID}Trimmed.fastq.gz $query -m ${params.read_min_length}
    """
    /* """
    fastqc --memory 2000 $query -t ${task.cpus}
    cutadapt --cut ${params.trim_end_size} --cut -${params.trim_end_size} -q ${params.quality_trim},${params.quality_trim} -o ${barID}Trimmed.fastq.gz $query -m ${params.read_min_length}
    fastqc --memory 2000 ${barID}Trimmed.fastq.gz -t ${task.cpus}
    multiqc .
    mv multiqc_report.html ${barID}_report.html
    """ */
}

/*
Assembling genome and plasmid with hybracter
Hybracter also compare putative plasmid with PLSDB using MASH (see plassember_summary.tsv)
For incomplete assembly, contigs are written in sample_final.fasta
*/
process ASSEMBLE_GENOME {  
    label 'process_high'
    publishDir "${params.output_dir}hybracter/"
    cpus { task.attempt < 2 ? task.cpus : 1 } //If blastx in dnaapler doesn't found hit fot certain seq length, there is a segmentation fault (temporary fix: reduce cpus to 1)
    errorStrategy { task.attempt < 3 ? 'retry' : 'ignore'}

    input:
    tuple val(barID), path(fastq), val(genome_size), path(sr1), path(sr2)
    
    output:
    tuple val(barID), path(fastq),path("${barID}_sample_per_contig_stats.tsv"), path("${barID}_plassembler_summary.tsv"), path("${barID}_sample_chromosome.fasta"), path("${barID}_hybracter_plasmid.fasta"), optional: true, emit: complete_assembly
    tuple val(barID), path(fastq),path("${barID}_sample_final.fasta"), optional: true, emit: incomplete_assembly

    script:
    def args = " "
    if (sr1 == [] || sr2 == []){ //if no short reads
        args = "long-single -l $fastq -t ${task.cpus} --min_length ${params.read_min_length} --flyeModel ${params.flyeModel}"
    }
    else {
        args = "hybrid-single -l $fastq -1 $sr1 -2 $sr2 -t ${task.cpus} --min_length ${params.read_min_length} --flyeModel ${params.flyeModel}"        
    }

    if (params.medaka == false) {
        args = args + " --no_medaka"
    }
    if(genome_size == 0){
        args = args + " --auto"
    }
    if(genome_size > 0){
        args = args + " -c ${genome_size}"
    }

    """
    hybracter ${args}
    
    [ ! -f hybracter_out/processing/plassembler/sample/plassembler_summary.tsv ] || mv hybracter_out/processing/plassembler/sample/plassembler_summary.tsv ${barID}_plassembler_summary.tsv
    [ ! -f hybracter_out/FINAL_OUTPUT/complete/sample_per_contig_stats.tsv ] || mv hybracter_out/FINAL_OUTPUT/complete/sample_per_contig_stats.tsv ${barID}_sample_per_contig_stats.tsv
    [ ! -f hybracter_out/FINAL_OUTPUT/complete/sample_chromosome.fasta ] || mv hybracter_out/FINAL_OUTPUT/complete/sample_chromosome.fasta ${barID}_sample_chromosome.fasta 
    [ ! -f hybracter_out/FINAL_OUTPUT/complete/sample_plasmid.fasta ] || mv hybracter_out/FINAL_OUTPUT/complete/sample_plasmid.fasta ${barID}_hybracter_plasmid.fasta

    [ ! -f hybracter_out/FINAL_OUTPUT/incomplete/sample_final.fasta ] || mv hybracter_out/FINAL_OUTPUT/incomplete/sample_final.fasta ${barID}_sample_final.fasta
    [ ! -f hybracter_out/FINAL_OUTPUT/incomplete/sample_per_contig_stats.tsv ] || mv hybracter_out/FINAL_OUTPUT/incomplete/sample_per_contig_stats.tsv ${barID}_sample_per_contig_stats.tsv
    """
}

/*
Busco assembly evaluation
*/
process BUSCO {
    label 'busco'
    publishDir "${params.output_dir}busco/"

    input:
    tuple val(barID), path(fasta)

    output:
    path("${barID}_busco.txt")
    script:
    """
    busco -i ${fasta} -m genome -l ${params.lineage_db} -o ${barID}_busco
    cp ${barID}_busco/short*.txt ${barID}_busco.txt
    """
}

/*
Identify AMR gene on plasmid and chromosome using abricate
*/
process IDENTIFY_AMR_PLASMID {
    label 'amr_detection'
    publishDir "${params.output_dir}final_output/"

    input:
    tuple val(barID) ,path(plasmid_fasta)

    output:
    tuple val(barID), path (plasmid_fasta),path("${barID}_plasmid_amr.txt"), emit: plasmid_amr

    script:
    """
    abricate -db ${params.amr_db} ${plasmid_fasta} > ${barID}_plasmid_amr.txt
    """
}

process IDENTIFY_AMR_CHRM {
    label 'amr_detection'
    publishDir "${params.output_dir}final_output/"

    input:
    tuple val(barID), path(chrm_fasta)

    output:
    tuple val(barID), path (chrm_fasta),path("${barID}_chrm_amr.txt"), emit: chrm_amr
    
    script:
    """
    abricate -db ${params.amr_db} ${chrm_fasta} > ${barID}_chrm_amr.txt
    """
}

//Filter circular plasmid in a fasta file from a tab file
process FILTER_CIRCULAR_PLASMID {
    publishDir "${params.output_dir}hybracter/"

    input:
    tuple val(barID), path(tab_file), path(chromosome),path(putative_plasmid)
    
    output:
    tuple val(barID), path(chromosome), path("${barID}_plasmid.fasta"), path("${barID}_putative_plasmid.fasta")

    script: 
    """
    awk '\$5 == "True" && \$2 == "plasmid" { print \$1 }' ${tab_file} > hybracter_circular_plasmid.txt
    seqkit grep -f hybracter_circular_plasmid.txt ${putative_plasmid} -o ${barID}_plasmid.fasta

    awk '\$5 == "False" && \$2 == "plasmid" { print \$1 }' ${tab_file} > hybracter_non_circular_plasmid.txt
    seqkit grep -f hybracter_non_circular_plasmid.txt ${putative_plasmid} -o ${barID}_putative_plasmid.fasta
    """    
}

//Infer contig from a fasta file
process PLASME_COMPLETE {
    label 'plasme'
    publishDir "${params.output_dir}plasme_output/"

    input:
    tuple val(barID), path(chromosome), path(plasmid), path(putative_plasmid)
    val x

    output:
    tuple val(barID), path("${barID}_final_chrm.fasta"), path("${barID}_final_plasmid.fasta")
    
    """
    PLASMe.py ${putative_plasmid} ${barID}_plasme.fasta -d ${params.plasme_db}
    awk ' { print \$1 }' ${barID}_plasme.fasta_report.csv > chrm_contig.txt
    seqkit grep --invert-match -f chrm_contig.txt ${putative_plasmid} -o ${barID}_plasme_chrm.fasta
    cat ${barID}_plasme_chrm.fasta > ${barID}_final_chrm.fasta
    cat ${chromosome} >> ${barID}_final_chrm.fasta
    cat ${barID}_plasme.fasta > ${barID}_final_plasmid.fasta
    cat ${plasmid} >> ${barID}_final_plasmid.fasta
    touch test.txt
    """
}

process PLASME_INCOMPLETE {
    label 'plasme'
    publishDir "${params.output_dir}plasme_output/"

    input:
    tuple val(barID), path(fastq), path(sample_fasta)
    val x

    output:
    tuple val(barID), path(fastq), path("${barID}_plasme_chrm.fasta"), path("${barID}_plasme_plasmid.fasta"), emit: inferred_plasmid
    val x

    script:
    """
    PLASMe.py ${sample_fasta} ${barID}_plasme_plasmid.fasta -d ${params.plasme_db}
    awk ' { print \$1 }' ${barID}_plasme_plasmid.fasta_report.csv > chrm_contig.txt
    seqkit grep -v -f chrm_contig.txt ${sample_fasta} -o ${barID}_plasme_chrm.fasta
    
    """
}   


//Align and filtered reads on infered plasmid.
process ALIGN_READS_PLASMID {
    label 'process_high'
    
    input:
    tuple val(barID), path(fastq),path(inferred_chrms_fasta),path(inferred_plasmid_fasta)

    output:
    tuple val(barID), path("${barID}_mapped_reads.fastq") , emit: plasmid_reads
    tuple val(barID), path("${barID}_unmapped_reads.fastq"), emit: chrm_reads

    script:
    """
    minimap2 -ax map-ont ${inferred_plasmid_fasta} ${fastq} > aln.sam
    samtools view -Sb -o aln.bam aln.sam
    samtools sort aln.bam -o aln_sorted.bam
    samtools index aln_sorted.bam

    samtools view -b -F 4 aln_sorted.bam > mapped_reads.bam
    samtools fastq mapped_reads.bam > ${barID}_mapped_reads.fastq

    samtools view -b -f 4 aln_sorted.bam > ${barID}_unmapped_reads.bam
    samtools fastq ${barID}_unmapped_reads.bam > ${barID}_unmapped_reads.fastq

    """
}

//Plasmid assembly with unicycler
process ASSEMBLY_PLASMID {
    label 'process_high'
    publishDir "${params.output_dir}plasme_assembly/"
    errorStrategy "ignore" //When depth is low, assembly is not possible and there is no result

    input:
    tuple val(barID), path(plasmid_reads)

    output:
    tuple val(barID), path("${barID}_plasme_plasmid.fasta")

    script:
    """
    if [ ! -s ${plasmid_reads} ]
    then
        touch ${barID}_plasme_plasmid.fasta
    else
        unicycler -l ${plasmid_reads} -o ${barID}_plasme_plasmid -t ${task.cpus}
        mv ${barID}_plasme_plasmid/assembly.fasta ${barID}.fasta
        awk '/^>/ {print \$0 "_plasmid"; next} {print \$0}' ${barID}.fasta > ${barID}_plasme_plasmid.fasta
    fi
    """
}

//chrm assembly with flye
process ASSEMBLY_CHRM {
    label 'process_high'
    publishDir "${params.output_dir}plasme_assembly/"

    input:
    tuple val(barID), path(chrm_reads)

    output:
    tuple val(barID), path("${barID}_plasme_chrm.fasta")

    script:
    """
    if [ ! -s ${chrm_reads} ]
    then
        touch ${barID}_plasme_chrm.fasta
    else
        flye --nano-hq ${chrm_reads} -t ${task.cpus} -o flye_output
        mv flye_output/assembly.fasta ${barID}.fasta
        awk '/^>/ {print  \$0 "_chromosome"; next} {print \$0}' ${barID}.fasta > ${barID}_plasme_chrm.fasta
    fi
    """
}

/*
Add BarID for each plasmids id
*/
process CHANGE_PLASMID_NAME {
    cpus 1

    input:
    tuple val(barID) ,path(plasmid_fasta)

    output:
    tuple val(barID) ,path("plasmids.fasta")

    script:
    """
    awk '/^>/ {\$0 = ">${barID}_" substr(\$0, 2); gsub(" ", "_", \$0)} 1' ${plasmid_fasta} > plasmids.fasta
    """
}

process MOB_TYPER {
    label 'mob'

    input:
    tuple val(barID) ,path(plasmid_fasta)

    output:
    tuple val(barID) ,path("plasmid_type.txt"), optional: true

    script:
    """
    mob_typer --multi --infile ${plasmid_fasta} --out_file plasmid_type.txt
    """
}

process MERGE_TYPE {

    publishDir "${params.output_dir}plasmid_annotation/"

    input:
    path(all_plasmid_type)

    output:
    path("mergeAll_type.txt")

    script:
    """
    echo "sample_id	num_contigs	size	gc	md5	rep_type(s)	rep_type_accession(s)	relaxase_type(s)	relaxase_type_accession(s)	mpf_type	mpf_type_accession(s)	orit_type(s)	orit_accession(s)	predicted_mobility	mash_nearest_neighbor	mash_neighbor_distance	mash_neighbor_identification	primary_cluster_id	secondary_cluster_id	predicted_host_range_overall_rank	predicted_host_range_overall_name	observed_host_range_ncbi_rank	observed_host_range_ncbi_name	reported_host_range_lit_rank	reported_host_range_lit_name	associated_pmid(s)" > mergeAll_type.txt
    sed '/^sample_id/d' ${all_plasmid_type} >> "mergeAll_type.txt"
    """
}


process CREATE_TAXA {
    
    input:
    tuple val(barID) ,path(plasmid_type)

    output:
    path "plasmid_tax.txt"

    script:
    """
    tail -n +2 ${plasmid_type} | cut -f1 -d\$'\t' | awk  -F'\t' '{print \$1 "\t${barID}"}' >> plasmid_tax.txt

    """
}

process MERGE_TAXA {
    publishDir "${params.output_dir}plasmid_annotation/"

    input:
    path(all_plasmid_tax)

    output:
    path("plasmidsAll_sample.txt")

    script:
    """
    echo "sample_id\ttaxonomy" > plasmidsAll_sample.txt
    cat ${all_plasmid_tax} >> plasmidsAll_sample.txt
    """
}

process MOB_CLUSTER {
    label 'mob'
    publishDir "${params.output_dir}plasmid_annotation/"

    input:
    path(plasmids_tax)
    path(plasmids_fasta)
    path(plasmids_type)

    output:
    path("clusters.txt")

    script:
    """
    mob_cluster  --mode build -f ${plasmids_fasta} -t ${plasmids_tax} -p ${plasmids_type} -o output
    mv output/clusters.txt clusters.txt
    """
}

process INTEGRON_FINDER_PLASMID {

    publishDir "${params.output_dir}intergron_finder/"

    input:
    tuple val(barID) ,path(plasmid_fasta)

    output:
    tuple val(barID) ,path("${barID}_plasmid_integron.txt")

    script:
    file_name = plasmid_fasta.getSimpleName()
    """
    integron_finder --local-max ${plasmid_fasta}
    mv Results_Integron_Finder_${file_name}/${file_name}.integrons ${barID}_plasmid_integron.txt
    """
}

process INTEGRON_FINDER_CHROMOSOME {

    publishDir "${params.output_dir}intergron_finder/"

    input:
    tuple val(barID) ,path(chromosome_fasta)

    output: 
    tuple val(barID) ,path("${barID}_chromosome_integron.txt") 

    script:
    file_name = chromosome_fasta.getSimpleName()
    """
    integron_finder --local-max ${chromosome_fasta}
    mv Results_Integron_Finder_${file_name}/${file_name}.integrons ${barID}_chromosome_integron.txt
    """
}

process INTEGRON_FORMAT {
    publishDir "${params.output_dir}intergron_finder/"

    input:
    tuple val(barID) ,path(integron)

    output:
    tuple val(barID) ,path("${file_name}_summary.txt")

    script:
    file_name = integron.getSimpleName()
    """
    awk '
    BEGIN { OFS="\t"; print "Integron_ID", "Replicon_ID" , "Start_Position", "End_Position", "Type" }
    \$1 ~ /^integron_/ && \$11 ~ /(complete|CALIN)/ {
        if (!seen[\$1]++) {
            min_pos[\$1] = \$4
            max_pos[\$1] = \$5
            type[\$1] = \$11
            replicon[\$1] = \$2
        } else {
            if (\$4 < min_pos[\$1]) min_pos[\$1] = \$4
            if (\$5 > max_pos[\$1]) max_pos[\$1] = \$5
        }
    }
    END {
        for (id in seen) {
            print id, replicon[id], min_pos[id], max_pos[id], type[id]
        }
    }' ${integron} > ${file_name}_summary.txt

    """
}

process KRAKEN {
    label 'process_high'

    input:
    tuple val(barID) ,path(chromosome_fasta)
    val x

    output:
    tuple val(barID) ,path("${barID}_kraken.txt")

    script:
    """
    kraken2 --db ${params.kraken_db} --threads ${task.cpus} --input ${chromosome_fasta} --use-names --report kraken.txt
    echo "${barID} \n" >> ${barID}_kraken.txt
    cat kraken.txt >> ${barID}_kraken.txt
    echo "\n" >> ${barID}_kraken.txt

    """
}

process MLST {
    label 'process_high'

    input:
    tuple val(barID) ,path(chromosome_fasta)
    
    output:
    tuple val(barID) ,path("${barID}_mlst.txt")

    script:
    """
    mlst ${chromosome_fasta} > ${barID}_mlst.txt
    """
}

/*
Blast for virulence factors and keeps track of unique values (gene) in column 2
*/
process VF_BLAST {
    publishDir "${params.output_dir}vf_blast/"
    label 'process_high'

    input:
    tuple val(barID) ,path(fasta)

    output:
    tuple val(barID) ,path("${sample}_vf_blast.txt")

    script:
    sample = fasta.getSimpleName()
    """
    blastn -db ${params.vf_db} -query ${fasta} -out vf_blast.txt -outfmt '6 stitle qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore' -num_threads ${task.cpus}
    awk '!seen[\$2]++ {print \$0}' vf_blast.txt > ${sample}_vf_blast.txt
    """
}
