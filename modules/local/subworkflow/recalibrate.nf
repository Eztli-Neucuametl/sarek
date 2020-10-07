/*
================================================================================
                                   RECALIBRATE
================================================================================
*/

include { GATK_APPLYBQSR as APPLYBQSR } from '../../nf-core/software/gatk/applybqsr'
include { MERGE_BAM }                   from '../process/merge_bam'
include { SAMTOOLS_STATS }              from '../../nf-core/software/samtools/stats'
include { SAMTOOLS_INDEX }              from '../../nf-core/software/samtools/index'
include { QUALIMAP_BAMQC }              from '../../nf-core/software/qualimap_bamqc'

workflow RECALIBRATE {
    take:
        skip_bamqc     // boolean: true/false
        skip_samtools  // boolean: true/false
        bam            // channel: [mandatory] bam
        dict           // channel: [mandatory] dict
        fai            // channel: [mandatory] fai
        fasta          // channel: [mandatory] fasta
        intervals      // channel: [mandatory] intervals
        modules        //     map: options for modules
        step           //   value: [mandatory] starting step
        target_bed     // channel: [optional]  target_bed

    main:

    bam_recalibrated_index = Channel.empty()
    bam_recalibrated       = Channel.empty()
    bam_reports            = Channel.empty()

    if (step in ["mapping", "preparerecalibration", "recalibrate"]) {

        bam_intervals = bam.combine(intervals)

        APPLYBQSR(bam_intervals, dict, fasta, fai)

        // STEP 4.5: MERGING AND INDEXING THE RECALIBRATED BAM FILES
        if (params.no_intervals) {
            bam_recalibrated = APPLYBQSR.out.bam
            tsv_recalibrated = APPLYBQSR.out.tsv
        } else {
            APPLYBQSR.out.bam.map{ meta, bam -> //, bai ->
                patient = meta.patient
                sample  = meta.sample
                gender  = meta.gender
                status  = meta.status
                [patient, sample, gender, status, bam] //, bai]
            }.groupTuple(by: [0,1]).set{ bam_recalibrated_interval }

            bam_recalibrated_interval = bam_recalibrated_interval.map {
                patient, sample, gender, status, bam -> //, bai ->

                def meta = [:]
                meta.patient = patient
                meta.sample = sample
                meta.gender = gender[0]
                meta.status = status[0]
                meta.id = sample

                [meta, bam]
            }

            MERGE_BAM(bam_recalibrated_interval, modules['merge_bam_recalibrate'])
            bam_recalibrated = MERGE_BAM.out.bam
            tsv_recalibrated = MERGE_BAM.out.tsv
        }

        bam_recalibrated_index = SAMTOOLS_INDEX(bam_recalibrated, modules['samtools_index_recalibrate'])

        qualimap_bamqc = Channel.empty()
        samtools_stats = Channel.empty()

        if (!skip_bamqc) {
            QUALIMAP_BAMQC(bam_recalibrated, target_bed)
            qualimap_bamqc = QUALIMAP_BAMQC.out
        }

        if (!skip_samtools) {
            SAMTOOLS_STATS(bam_recalibrated)
            samtools_stats = SAMTOOLS_STATS.out
        }

        bam_reports = samtools_stats.mix(qualimap_bamqc)

        //TODO: set bam_recalibrated with all these steps
        // // When using sentieon for mapping, Channel bam_recalibrated is bam_sentieon_recal
        // if (params.sentieon && step == 'mapping') bam_recalibrated = bam_sentieon_recal

        // // When no knownIndels for mapping, Channel bam_recalibrated is bam_duplicates_marked
        // if (!params.known_indels && step == 'mapping') bam_recalibrated = bam_duplicates_marked

        // // When starting with variant calling, Channel bam_recalibrated is input_sample
        // if (step == 'variantcalling') bam_recalibrated = input_sample
        // Creating TSV files to restart from this step
        tsv_recalibrated.collectFile(storeDir: "${params.outdir}/Preprocessing/TSV") { meta ->
            patient = meta.patient
            sample  = meta.sample
            gender  = meta.gender
            status  = meta.status
            bam = "${params.outdir}/Preprocessing/${sample}/Recalibrated/${sample}.md.bam"
            bai = "${params.outdir}/Preprocessing/${sample}/Recalibrated/${sample}.md.bam.bai"
            ["recalibrated_${sample}.tsv", "${patient}\t${gender}\t${status}\t${sample}\t${bam}\t${bai}\n"]
        }

        tsv_recalibrated.map { meta ->
            patient = meta.patient
            sample  = meta.sample
            gender  = meta.gender
            status  = meta.status
            bam = "${params.outdir}/Preprocessing/${sample}/Recalibrated/${sample}.md.bam"
            bai = "${params.outdir}/Preprocessing/${sample}/Recalibrated/${sample}.md.bam.bai"
            "${patient}\t${gender}\t${status}\t${sample}\t${bam}\t${bai}\n"
        }.collectFile(name: 'recalibrated.tsv', sort: true, storeDir: "${params.outdir}/Preprocessing/TSV")
    }

    emit:
        bam = bam_recalibrated_index
        qc  = bam_reports
}
