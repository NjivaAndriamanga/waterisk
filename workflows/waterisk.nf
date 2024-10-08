
log.info "\n"
log.info "========================================================================================="
log.info "Welcome to the WATERISK pipeline. For any questions or remarks, please contact the author \n"
log.info "=========================================================================================="
log.info "\n"

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PARAMETERS MANAGMENT
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { validateParameters; paramsHelp; paramsSummaryLog; fromSamplesheet } from 'plugin/nf-validation'

//print help message, supply typical command line usage for the pipeline
if (params.help) {
    log.info paramsHelp("nextflow run waterisk --profile perso")
    exit 0
}

//
validateParameters()

//Print summary of supplied parameters
log.info paramsSummaryLog(workflow)

//Check if the input dir exists


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    DEF FUNCTION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def check_nonCircularPlasmid(tsv_file) {
    def rows = tsv_file.readLines() // Read the file line by line
    def header = rows[0].split('\t') // Assuming the CSV is comma-separated
    // Iterate through each row (starting from the second, since the first is the header)
    for (def i = 1; i < rows.size(); i++) {
        def row = rows[i].split('\t')
        if (row[4] == 'False' && row[0].contains('plasmid')) {
            return true // Return true if both conditions are satisfied
        }
    }
    return false // Return false if no row matches the conditions
}

def check_plasmidAllCircular(tsv_file) {
    def rows = tsv_file.readLines() // Read the file line by line
    def header = rows[0].split('\t') // Assuming the CSV is comma-separated
    // Iterate through each row (starting from the second, since the first is the header)
    for (def i = 1; i < rows.size(); i++) {
        def row = rows[i].split('\t')
        if (row[4] == 'False' && row[0].contains('plasmid')) {
            return false // Return true if both conditions are satisfied
        }
    }
    return true // Return false if no row matches the conditions
}



/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { DOWNLOAD_DATABASE }       from '../modules/waterisk_modules.nf'
include { IDENTIFIED_RAW_SAMPLES }  from '../modules/waterisk_modules.nf'
include { IDENTIFIED_SAMPLES}       from '../modules/waterisk_modules.nf'
include { MERGE_SEPARATE_FASTQ }    from '../modules/waterisk_modules.nf'
include { REMOVE_BARCODES }         from '../modules/waterisk_modules.nf'
include { CLEAN_READS }             from '../modules/waterisk_modules.nf'
include { SAMPLING_FASTQ }          from '../modules/waterisk_modules.nf'
include { ASSEMBLE_GENOME }         from '../modules/waterisk_modules.nf'
include { FILTER_CIRCULAR_PLASMID } from '../modules/waterisk_modules.nf'
include { IDENTIFY_AMR_PLASMID }    from '../modules/waterisk_modules.nf'
include { IDENTIFY_AMR_CHRM }       from '../modules/waterisk_modules.nf'
include { PLASME }                  from '../modules/waterisk_modules.nf'
include { ALIGN_READS_PLASMID }     from '../modules/waterisk_modules.nf'
include { ASSEMBLY_PLASMID }        from '../modules/waterisk_modules.nf'
include { ASSEMBLY_CHRM}            from '../modules/waterisk_modules.nf'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow WATERISK {
    
    //download database
    DOWNLOAD_DATABASE().view()

    //if raw output from MINION
    if (params.raw == true){
        IDENTIFIED_RAW_SAMPLES(file(params.fastq_pass_dir), params.fastq_pass_dir)
        (fastq) = MERGE_SEPARATE_FASTQ(IDENTIFIED_SAMPLES.out.flatten())
    }
    else {
        def fastqs = Channel.fromPath(params.fastq_pass_dir + "*.fastq.gz")
        fastq = IDENTIFIED_SAMPLES(fastqs)
    }
    
    
    //Remove barcode then trim reads
    if (params.remove_barcode == true){
        (fastq_nobar) = REMOVE_BARCODES(fastq)
        CLEAN_READS(fastq_nobar)
    }
    else {
        CLEAN_READS(fastq)
    }

    //De novo assembly using Hybracter
    ASSEMBLE_GENOME(CLEAN_READS.out.trimmed_fastq)

    //Filtering complete where all plasmid is circular (1), complete but with non-circular plasmid (2) and incomplete (3)
    complete_assembly_ch = ASSEMBLE_GENOME.out.complete_assembly

    complete_non_circular_ch = complete_assembly_ch //2
        .filter{ barID, fastq, contig_stats, plassembler, chromosome, plasmids -> 
            check_nonCircularPlasmid(contig_stats)}

    complete_circular_ch = ASSEMBLE_GENOME.out.complete_assembly //1
        .filter{ barID, fastq, contig_stats, plassembler, chromosome, plasmids -> 
            check_plasmidAllCircular(contig_stats)}
    
    incomplete_assembly_ch = ASSEMBLE_GENOME.out.incomplete_assembly //3
    //incomplete_assembly_ch.count().view()

    //complete_circular_ch.count().view(it -> "$it samples have complete assembly")
    //complete_non_circular_ch.count().view( it -> "$it have non circular plasmid")
    
    //Remove circular plasmid from complete assembly
    putitative_plasmid_ch = complete_non_circular_ch.map{ barID, fastq, contig_stats, plassembler, chromosome, plasmids -> 
                                                                                                                [ barID, fastq, contig_stats, plasmids]}
    FILTER_CIRCULAR_PLASMID(putitative_plasmid_ch)

    //Infer plasmid contig and chomosomal contig
    plasme_input_ch = FILTER_CIRCULAR_PLASMID.out.non_circular_plasmid.concat(incomplete_assembly_ch)
    PLASME(plasme_input_ch, DOWNLOAD_DATABASE.out)

    //Align reads and filter plasmid reads
    align_reads_input_ch = FILTER_CIRCULAR_PLASMID.out.circular_plasmid.join(PLASME.out.inferred_plasmid_fasta)
    ALIGN_READS_PLASMID(align_reads_input_ch)
    
    //Assembly with reads matching plasme plasmid
    ASSEMBLY_PLASMID(ALIGN_READS_PLASMID.out.plasmid_reads)
    ASSEMBLY_CHRM( ALIGN_READS_PLASMID.out.chrm_reads)

    //AMR detection
    complete_circular_chrm_ch = complete_circular_ch.map{ barID, fastq, contig, plassembler, chromosome, plasmid -> [barID, chromosome]}
    complete_circular_plasmid_ch = complete_circular_ch.map{ barID, fastq, contig, plassembler, chromosome, plasmid -> [barID, plasmid]}
    
    chrm_amr_ch = complete_circular_chrm_ch.concat(ASSEMBLY_CHRM.out)
    plasmid_amr_ch = complete_circular_plasmid_ch.concat(ASSEMBLY_PLASMID.out)

    IDENTIFY_AMR_PLASMID( plasmid_amr_ch )
    IDENTIFY_AMR_CHRM( chrm_amr_ch)

}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
