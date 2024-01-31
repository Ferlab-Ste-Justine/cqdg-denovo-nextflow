process combineGVCF {
    label 'medium'

    container 'broadinstitute/gatk'
    input:
    val familyId
    path gvcfFiles
    path referenceGenome

    output:
    path "*combined.gvcf.gz*"

    script:
    def exactGvcfFiles = gvcfFiles.findAll { it.name.endsWith("gvcf.gz") }.collect { "--variant $it" }.join(' ')

    """
    gatk CombineGVCFs -R $referenceGenome/${params.referenceGenomeFasta} $exactGvcfFiles -O ${familyId}.combined.gvcf.gz
    """    

}    

process genotypeGVCF {
    label 'geno'

    container 'broadinstitute/gatk'

    input:
    val familyId
    path gvcfFile
    path referenceGenome

    output:
    path "*genotyped.vcf.gz*"

    script:
    def exactGvcfFile = gvcfFile.find { it.name.endsWith("gvcf.gz") }
    """
    gatk --java-options "-Xmx24g" GenotypeGVCFs -R $referenceGenome/${params.referenceGenomeFasta} -V $exactGvcfFile -O ${familyId}.genotyped.vcf.gz
    """

}

process splitMultiAllelics{
    label 'medium'

    container 'broadinstitute/gatk:4.1.4.1'
    
    input:
    val familyId
    path vcfFile
    path referenceGenome

    output:
    path "*splitted.vcf*"

    script:
    def exactVcfFile = vcfFile.find { it.name.endsWith("vcf.gz") }
    """
    gatk LeftAlignAndTrimVariants -R $referenceGenome/${params.referenceGenomeFasta} -V $exactVcfFile -O ${familyId}.splitted.vcf.gz --split-multi-allelics
    """
}

process vep {
    label 'vep'

    container 'ensemblorg/ensembl-vep'
    
    input:
    val familyId
    path vcfFile
    path referenceGenome
    path vepCache

    output:
    path "*vep.vcf.gz"

    script:
    def exactVcfFile = vcfFile.find { it.name.endsWith("vcf.gz") }
    """
    vep \
    --fork ${params.vepCpu} \
    --dir ${vepCache} \
    --offline \
    --cache \
    --fasta $referenceGenome/${params.referenceGenomeFasta} \
    --input_file $exactVcfFile \
    --format vcf \
    --vcf \
    --output_file variants.${familyId}.vep.vcf.gz \
    --compress_output bgzip \
    --xref_refseq \
    --variant_class \
    --numbers \
    --hgvs \
    --hgvsg \
    --canonical \
    --symbol \
    --flag_pick \
    --fields "Allele,Consequence,IMPACT,SYMBOL,Feature_type,Gene,PICK,Feature,EXON,BIOTYPE,INTRON,HGVSc,HGVSp,STRAND,CDS_position,cDNA_position,Protein_position,Amino_acids,Codons,VARIANT_CLASS,HGVSg,CANONICAL,RefSeq" \
    --no_stats
    """
}

process tabix {
    label 'tiny'

    container 'staphb/htslib'

    input:
    path vcfFile

    output:
    path "*.tbi"

    script:
    """
    tabix $vcfFile
    """

}

process copyFinalDestination {
    label 'tiny'

    input:
    path destination
    path vcfFile
    path tbiFile

    output:
    stdout

    script:
    """
    cp -f $vcfFile $destination/
    cp -f $tbiFile $destination/
    """

}    

def sampleChannel() {
   return Channel.fromPath(file("$params.sampleFile"))
               .splitCsv(sep: '\t');
}

workflow {

    families = sampleChannel()
               .map { it[0] }

    gvcfs = sampleChannel()
               .map { it.tail().collect{ f -> file("${f}*")}.flatten()}       

    referenceGenome = file(params.referenceGenome)
    vepCache = file(params.vepCache)
    finalDestination = file(params.finalDestination)

    finalDestination.mkdirs()
    families | view
    gvcfs | view
    combineGVCF(families, gvcfs, referenceGenome) | view
    genotypeGVCF(families, combineGVCF.out, referenceGenome) | view
    splitMultiAllelics(families, genotypeGVCF.out, referenceGenome) | view
    vep(families, splitMultiAllelics.out, referenceGenome, vepCache) | view
    tabix(vep.out) | view

    copyFinalDestination(finalDestination, vep.out, tabix.out)


}